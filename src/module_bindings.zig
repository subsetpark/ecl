//! Publication of adapter-provided module constants. Definitions describe
//! ordinary words; neither their provider nor their values have a source family.
const std = @import("std");
const Value = @import("value.zig").Value;
const InheritedContext = @import("machine.zig").InheritedContext;

pub const Definition = struct { name: []const u8, doc: []const u8, effect: []const u8 };
const RegistrationState = struct {
    declarations: []const Definition,
    bind: *const fn (std.mem.Allocator, *const InheritedContext) error{OutOfMemory}!*Publication,
};
pub const Registration = opaque {
    fn state(self: *const Registration) *const RegistrationState {
        return @ptrCast(@alignCast(self));
    }
    pub fn create(comptime Adapter: type) *const Registration {
        comptime {
            for (Adapter.definitions, 0..) |definition, index| {
                for (Adapter.definitions[0..index]) |previous| {
                    if (std.mem.eql(u8, definition.name, previous.name))
                        @compileError("duplicate module binding name: " ++ definition.name);
                }
            }
        }
        const Static = struct {
            const descriptor: RegistrationState = .{ .declarations = Adapter.definitions, .bind = Adapter.bind };
        };
        return @ptrCast(&Static.descriptor);
    }
    pub fn declarations(self: *const Registration) []const Definition {
        return self.state().declarations;
    }
    pub fn bind(self: *const Registration, allocator: std.mem.Allocator, inherited: *const InheritedContext) error{OutOfMemory}!*Publication {
        return self.state().bind(allocator, inherited);
    }
};

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

const State = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    payload: *anyopaque,
    definitions: []const Definition,
    seal: *const fn (*anyopaque, usize) error{OutOfMemory}!Value,
    release: *const fn (*anyopaque) void,
};

pub const Publication = opaque {
    fn state(self: *Publication) *State {
        return @ptrCast(@alignCast(self));
    }
    /// Success consumes the bound provider; failure retains it. Each sealed
    /// value owns its independent issuer pin through publication or rollback.
    pub fn create(comptime Adapter: type, adapter: *Adapter) error{OutOfMemory}!*Publication {
        const Bridge = struct {
            fn typed(raw: *anyopaque) *Adapter {
                return @ptrCast(@alignCast(raw));
            }
            fn seal(raw: *anyopaque, index: usize) error{OutOfMemory}!Value {
                return typed(raw).seal(index);
            }
            fn release(raw: *anyopaque) void {
                typed(raw).release();
            }
        };
        const owned = try adapter.allocator().create(State);
        owned.* = .{ .allocator = adapter.allocator(), .payload = adapter, .definitions = Adapter.definitions, .seal = Bridge.seal, .release = Bridge.release };
        return @ptrCast(owned);
    }
    pub fn declarations(self: *Publication) []const Definition {
        return self.state().definitions;
    }
    pub fn seal(self: *Publication, index: usize) error{OutOfMemory}!Value {
        return self.state().seal(self.state().payload, index);
    }
    pub fn retain(self: *Publication) void {
        _ = self.state().refs.fetchAdd(1, .monotonic);
    }
    pub fn release(self: *Publication) void {
        const owned = self.state();
        if (owned.refs.fetchSub(1, .acq_rel) != 1) return;
        owned.release(owned.payload);
        owned.allocator.destroy(owned);
    }
};
