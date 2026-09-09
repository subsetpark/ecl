//! Package-facing Zig API.
//!
//! The implementation aggregation remains private so a declaration made
//! public for cross-file use does not silently become part of this API.
const std = @import("std");
const internal = @import("internal.zig");

pub const version = internal.version;

pub const Value = internal.value.Value;
pub const ValueTag = internal.value.Tag;
pub const HeapKind = internal.value.HeapKind;

pub const Session = internal.session.Session;
pub const SessionInitError = internal.session.InitError;
pub const UnitOutcome = internal.session.UnitOutcome;
pub const SessionConfig = internal.session.Config;
pub const default_worker_count = internal.session.default_worker_count;
pub const TlsTrustOverride = internal.session.TlsTrustOverride;
pub const WallClockPolicy = internal.session.WallClockPolicy;
pub const ClockPolicy = internal.session.ClockPolicy;
pub const Host = internal.session.Host;
pub const CompletionSet = internal.session.CompletionSet;
pub const RenderedText = internal.session.RenderedText;
pub const RootPreloadProgress = internal.session.RootPreloadProgress;
pub const EditorTerminal = internal.session.EditorTerminal;
pub const RowTerminal = internal.session.RowTerminal;
pub const CompletionObserve = internal.session.CompletionObserve;

pub const EnvironmentEntry = internal.machine.Environ.Entry;
pub const StandardInputAvailability = internal.machine.StandardInput.Availability;
pub const MonotonicClockSource = internal.scheduler.ClockSource;

pub const ProcessLimits = internal.process_port.Limits;

pub const FilesystemConfig = internal.filesystem_port.Config;
pub const FilesystemRoot = internal.filesystem_port.Root;
pub const FilesystemLimits = internal.filesystem_port.Limits;

pub const NetLimits = internal.net_port.Limits;
pub const NativePortLimits = @FieldType(Host, "native_port_limits");

const public_declarations = [_][]const u8{
    "version",
    "Value",
    "ValueTag",
    "HeapKind",
    "Session",
    "SessionInitError",
    "UnitOutcome",
    "SessionConfig",
    "default_worker_count",
    "TlsTrustOverride",
    "WallClockPolicy",
    "ClockPolicy",
    "Host",
    "CompletionSet",
    "RenderedText",
    "RootPreloadProgress",
    "EditorTerminal",
    "RowTerminal",
    "CompletionObserve",
    "EnvironmentEntry",
    "StandardInputAvailability",
    "MonotonicClockSource",
    "ProcessLimits",
    "FilesystemConfig",
    "FilesystemRoot",
    "FilesystemLimits",
    "NetLimits",
    "NativePortLimits",
};

comptime {
    const declarations = std.meta.declarations(@This());
    if (declarations.len != public_declarations.len)
        @compileError("the package API must match its closed declaration list");
    for (declarations, public_declarations) |actual, expected| {
        if (!std.mem.eql(u8, actual.name, expected))
            @compileError("the package API must match its closed declaration list");
    }
}

test {
    _ = internal;
}
