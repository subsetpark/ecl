//! Nominal type-erased capabilities for scheduler-owned external resources.
//!
//! This is the only shared vocabulary between the scheduler and a concrete
//! backend. It deliberately contains no process, file-descriptor, or PID
//! types: an external resource can expose readiness and structured scope
//! membership without giving either side access to the other's representation.

const std = @import("std");

/// Nominal proof that a Session granted process creation authority. Concrete
/// controller ownership and policy remain private to `process_port.zig`.
pub const ProcessAccess = opaque {};

/// Nominal proof that a Session granted named filesystem roots. Root handles,
/// permissions, limits, and the live-operation quota remain private to
/// `filesystem_port.zig`; a Unit can neither mint nor widen one.
pub const FilesystemAccess = opaque {};

/// Nominal proof that a Session granted inbound listen authority. The bind
/// allowlist, limits, and live-listener quota remain private to
/// `net_port.zig`; a Unit can neither mint nor widen one.
pub const NetAccess = opaque {};

/// Nominal proof that a Session was constructed for a package command. It
/// carries the package store handles that `pkg.store` needs and nothing an
/// ordinary embedding Session ever mints; see `package_authority.zig`.
pub const PackageAccess = opaque {};

pub const Wake = enum {
    ready,
    io,
};

pub const RegisterError = error{OutOfMemory};

/// A stable callback target borrowed by `ReadinessSource.register`. A source
/// that stores the target must retain it before returning and release it only
/// after cancellation makes every future `wake` impossible.
pub const WakeTarget = struct {
    context: *anyopaque,
    retain_fn: *const fn (*anyopaque) void,
    release_fn: *const fn (*anyopaque) void,
    wake_fn: *const fn (*anyopaque, Wake) void,

    pub fn retain(self: WakeTarget) void {
        self.retain_fn(self.context);
    }

    pub fn release(self: WakeTarget) void {
        self.release_fn(self.context);
    }

    pub fn wake(self: WakeTarget, reason: Wake) void {
        self.wake_fn(self.context, reason);
    }
};

fn WakeTargetAdapters(comptime Payload: type) type {
    return struct {
        fn retain(raw: *anyopaque) void {
            Payload.retainExternalWake(@ptrCast(@alignCast(raw)));
        }

        fn release(raw: *anyopaque) void {
            Payload.releaseExternalWake(@ptrCast(@alignCast(raw)));
        }

        fn wake(raw: *anyopaque, reason: Wake) void {
            Payload.wakeExternal(@ptrCast(@alignCast(raw)), reason);
        }
    };
}

pub fn wakeTarget(comptime Payload: type, payload: *Payload) WakeTarget {
    const adapters = WakeTargetAdapters(Payload);
    return .{
        .context = @ptrCast(payload),
        .retain_fn = adapters.retain,
        .release_fn = adapters.release,
        .wake_fn = adapters.wake,
    };
}

/// Consuming cancellation authority for one registered external wait.
pub const ReadinessRegistration = struct {
    context: ?*anyopaque,
    cancel_fn: *const fn (*anyopaque) void,

    pub fn cancel(self: *ReadinessRegistration) void {
        const context = self.context orelse return;
        self.context = null;
        self.cancel_fn(context);
    }
};

fn ReadinessRegistrationAdapters(comptime Payload: type) type {
    return struct {
        fn cancel(raw: *anyopaque) void {
            Payload.cancelReadiness(@ptrCast(@alignCast(raw)));
        }
    };
}

pub fn readinessRegistration(
    comptime Payload: type,
    payload: *Payload,
) ReadinessRegistration {
    return .{
        .context = @ptrCast(payload),
        .cancel_fn = ReadinessRegistrationAdapters(Payload).cancel,
    };
}

pub const RegisterResult = union(enum) {
    ready: Wake,
    registered: ReadinessRegistration,
};

/// One retained, single-use description of an external readiness predicate.
/// The source owns its backend reference until `deinit`; registering does not
/// transfer that reference, and a successful registration owns an independent
/// reference until its consuming cancellation.
pub const ReadinessSource = struct {
    context: ?*anyopaque,
    key: u64,
    register_fn: *const fn (*anyopaque, u64, WakeTarget) RegisterError!RegisterResult,
    release_fn: *const fn (*anyopaque) void,

    pub fn register(
        self: *const ReadinessSource,
        target: WakeTarget,
    ) RegisterError!RegisterResult {
        return self.register_fn(self.context.?, self.key, target);
    }

    pub fn deinit(self: *ReadinessSource) void {
        const context = self.context orelse return;
        self.context = null;
        self.release_fn(context);
    }
};

fn ReadinessSourceAdapters(comptime Payload: type) type {
    return struct {
        fn register(
            raw: *anyopaque,
            key: u64,
            target: WakeTarget,
        ) RegisterError!RegisterResult {
            return Payload.registerReadiness(@ptrCast(@alignCast(raw)), key, target);
        }

        fn release(raw: *anyopaque) void {
            Payload.releaseReadiness(@ptrCast(@alignCast(raw)));
        }
    };
}

/// Retains `payload` and returns a source that must be deinitialized exactly
/// once, whether registration succeeds, loses a race, or is abandoned.
pub fn readinessSource(comptime Payload: type, payload: *Payload, key: u64) ReadinessSource {
    Payload.retainReadiness(payload);
    const adapters = ReadinessSourceAdapters(Payload);
    return .{
        .context = @ptrCast(payload),
        .key = key,
        .register_fn = adapters.register,
        .release_fn = adapters.release,
    };
}

/// One scheduler-owned reference to an external resource attached to a task
/// scope. Cancellation is idempotent; release consumes the retained reference.
pub const ScopeMember = struct {
    context: ?*anyopaque,
    retain_fn: *const fn (*anyopaque) void,
    release_fn: *const fn (*anyopaque) void,
    cancel_fn: *const fn (*anyopaque) void,

    pub fn retain(self: *const ScopeMember) void {
        self.retain_fn(self.context.?);
    }

    pub fn cancel(self: *const ScopeMember) void {
        self.cancel_fn(self.context.?);
    }

    pub fn deinit(self: *ScopeMember) void {
        const context = self.context orelse return;
        self.context = null;
        self.release_fn(context);
    }

    pub fn take(self: *ScopeMember) ScopeMember {
        const result = self.*;
        self.context = null;
        return result;
    }
};

fn ScopeMemberAdapters(comptime Payload: type) type {
    return struct {
        fn retain(raw: *anyopaque) void {
            Payload.retainExternalMember(@ptrCast(@alignCast(raw)));
        }

        fn release(raw: *anyopaque) void {
            Payload.releaseExternalMember(@ptrCast(@alignCast(raw)));
        }

        fn cancel(raw: *anyopaque) void {
            Payload.cancelExternalMember(@ptrCast(@alignCast(raw)));
        }
    };
}

/// Retains `payload`; the returned member owns that reference on every path.
pub fn scopeMember(comptime Payload: type, payload: *Payload) ScopeMember {
    Payload.retainExternalMember(payload);
    const adapters = ScopeMemberAdapters(Payload);
    return .{
        .context = @ptrCast(payload),
        .retain_fn = adapters.retain,
        .release_fn = adapters.release,
        .cancel_fn = adapters.cancel,
    };
}

/// Consuming detach authority returned only after a scheduler has linked an
/// external member. The backend stores this token and invokes it after its
/// terminal cleanup is complete.
pub const ScopeMembership = struct {
    context: ?*anyopaque,
    detach_fn: *const fn (*anyopaque) void,

    pub fn detach(self: *ScopeMembership) void {
        const context = self.context orelse return;
        self.context = null;
        self.detach_fn(context);
    }
};

fn ScopeMembershipAdapters(comptime Payload: type) type {
    return struct {
        fn detach(raw: *anyopaque) void {
            Payload.detachExternalMembership(@ptrCast(@alignCast(raw)));
        }
    };
}

pub fn scopeMembership(comptime Payload: type, payload: *Payload) ScopeMembership {
    return .{
        .context = @ptrCast(payload),
        .detach_fn = ScopeMembershipAdapters(Payload).detach,
    };
}

comptime {
    if (@sizeOf(ReadinessSource) > 4 * @sizeOf(usize))
        @compileError("external readiness source exceeds its fixed capability budget");
    if (@sizeOf(ScopeMember) > 4 * @sizeOf(usize))
        @compileError("external scope member exceeds its fixed capability budget");
}

test "external capabilities have consuming release surfaces" {
    const Probe = struct {
        refs: usize = 0,
        cancellations: usize = 0,
        detaches: usize = 0,

        fn retainExternalMember(self: *@This()) void {
            self.refs += 1;
        }
        fn releaseExternalMember(self: *@This()) void {
            self.refs -= 1;
        }
        fn cancelExternalMember(self: *@This()) void {
            self.cancellations += 1;
        }
        fn detachExternalMembership(self: *@This()) void {
            self.detaches += 1;
        }
    };
    var probe: Probe = .{};
    var member = scopeMember(Probe, &probe);
    try std.testing.expectEqual(@as(usize, 1), probe.refs);
    member.cancel();
    member.deinit();
    member.deinit();
    try std.testing.expectEqual(@as(usize, 1), probe.cancellations);
    try std.testing.expectEqual(@as(usize, 0), probe.refs);
    var membership = scopeMembership(Probe, &probe);
    membership.detach();
    membership.detach();
    try std.testing.expectEqual(@as(usize, 1), probe.detaches);
}
