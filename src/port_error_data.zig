//! Immutable diagnostics owned through final resource or exchange release.
const heap = @import("heap.zig");
const message = @import("port_message.zig");
const messages = @import("port_messages.zig");
const dict = @import("dict.zig");
const Value = @import("value.zig").Value;

pub const max_entries = 4;
pub const Observation = struct {
    report: @import("port_bytes.zig").Failure,
    details: ?*const View = null,
};

/// A terminal observer borrows this view from its retained issuing resource or
/// exchange. Closing that issuer does not retire diagnostics; final release does.
pub const View = opaque {
    fn envelope(self: *const View) *messages.Envelope {
        return @ptrCast(@constCast(self));
    }
    /// Independently retain immutable diagnostics in their issuing domain.
    /// Diagnostic envelopes never enter queues or carry mutable reservations.
    pub fn retain(self: *const View) *Owned {
        _ = self.envelope().borrow();
        return @ptrCast(@constCast(self));
    }
    pub fn len(self: *const View) usize {
        return @intCast(self.envelope().value().dict.length());
    }
    pub fn key(self: *const View, index: usize) u32 {
        return dict.keyAt(self.envelope().value().dict, index).symbol;
    }
    pub fn value(self: *const View, index: usize) Value {
        return dict.valueAt(self.envelope().value().dict, index);
    }
};

/// Only validated, capability-free dictionaries with bounded symbol keys may
/// become diagnostics. Creation retains the input on success and on failure.
pub const Owned = opaque {
    pub fn create(host: *const heap.HostCleanup, input: *const message.Validated) error{ OutOfMemory, InvalidValue }!*Owned {
        const value = input.value();
        if (value != .dict or value.dict.length() > max_entries or input.footprint().capabilities != 0) return error.InvalidValue;
        for (0..@intCast(value.dict.length())) |index| {
            if (dict.keyAt(value.dict, index) != .symbol) return error.InvalidValue;
        }
        return adopt(try messages.Envelope.create(host, input));
    }
    fn adopt(envelope: *messages.Envelope) *Owned {
        return @ptrCast(envelope);
    }
    pub fn view(self: *const Owned) *const View {
        return @ptrCast(self);
    }
    pub fn release(self: *Owned) void {
        const envelope: *messages.Envelope = @ptrCast(self);
        envelope.release();
    }
};
