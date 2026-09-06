//! Native image loading, descriptor ownership, and per-Session image pins.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("native-abi");
const descriptor_api = @import("native_descriptor.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");

const supported_platform = builtin.os.tag == .macos or
    (builtin.os.tag == .linux and builtin.link_libc and
        !(builtin.abi == .musl and builtin.link_mode == .static));

pub const LoadFailure = struct {
    bytes: [512]u8 = [_]u8{0} ** 512,
    len: usize = 0,

    pub fn text(self: *const LoadFailure) []const u8 {
        return self.bytes[0..self.len];
    }

    fn init(comptime format: []const u8, args: anytype) LoadFailure {
        var result = LoadFailure{};
        const rendered = std.fmt.bufPrint(&result.bytes, format, args) catch {
            const fallback = "native module load failed (diagnostic too long)";
            @memcpy(result.bytes[0..fallback.len], fallback);
            result.len = fallback.len;
            return result;
        };
        result.len = rendered.len;
        return result;
    }
};

pub const StartResult = union(enum) {
    loading: LoadCursor,
    failure: LoadFailure,
};

pub const LoadProgress = union(enum) {
    pending,
    loaded: *ModuleInstance,
    failure: LoadFailure,
};

const ImagePin = union(enum) {
    dynamic: std.DynLib,
    static,

    fn close(self: *ImagePin) void {
        switch (self.*) {
            .dynamic => |*library| library.close(),
            .static => {},
        }
    }
};

pub const Loading = union(enum) {
    opened: struct {
        loader: *Loader,
        requested: intern.ModuleName,
        image: ImagePin,
        entry: abi.EntryFn,
    },
    described: struct {
        loader: *Loader,
        requested: intern.ModuleName,
        image: ImagePin,
        descriptor: *const abi.Descriptor,
    },
    validated: struct {
        loader: *Loader,
        image: ImagePin,
        descriptor: *descriptor_api.ValidatedDescriptor,
    },
    initialized: struct {
        loader: *Loader,
        image: ImagePin,
        descriptor: *descriptor_api.ValidatedDescriptor,
    },
    published: *ModuleInstance,
};

/// Owns an opened image and the validator that is copying its descriptor.
/// One `advance` performs at most the caller's explicit validation budget.
pub const LoadCursor = struct {
    loader: *Loader,
    state: State,

    const State = union(enum) {
        validating: struct {
            image: ImagePin,
            validator: descriptor_api.ValidateCursor,
        },
        complete,
    };

    fn init(
        loader: *Loader,
        requested: intern.ModuleName,
        image: ImagePin,
        descriptor: *const abi.Descriptor,
    ) LoadCursor {
        return .{
            .loader = loader,
            .state = .{ .validating = .{
                .image = image,
                .validator = descriptor_api.ValidateCursor.init(
                    loader.state().host,
                    requested,
                    descriptor,
                ),
            } },
        };
    }

    pub fn deinit(self: *LoadCursor) void {
        switch (self.state) {
            .validating => |*validating| {
                validating.validator.deinit();
                validating.image.close();
            },
            .complete => {},
        }
        self.state = .complete;
    }

    pub fn advance(self: *LoadCursor, budget: usize) error{OutOfMemory}!LoadProgress {
        std.debug.assert(self.state == .validating and budget != 0);
        const validating = &self.state.validating;
        const progress = validating.validator.advance(budget) catch |err| switch (err) {
            error.OutOfMemory => {
                self.deinit();
                return error.OutOfMemory;
            },
            else => {
                const failing_definition = validating.validator.failingDefinition();
                const failure: LoadFailure = if (failing_definition) |index|
                    .init(
                        "native descriptor rejected: {s} at definition {d}",
                        .{ @errorName(err), index },
                    )
                else
                    .init("native descriptor rejected: {s}", .{@errorName(err)});
                self.deinit();
                return .{ .failure = failure };
            },
        };
        return switch (progress) {
            .pending => .pending,
            .complete => |descriptor| complete: {
                const image = validating.image;
                self.state = .complete;
                const validated: Loading = .{ .validated = .{
                    .loader = self.loader,
                    .image = image,
                    .descriptor = descriptor,
                } };
                const initialized = initialize(validated);
                const published = publish(initialized) catch return error.OutOfMemory;
                break :complete .{ .loaded = published.published };
            },
        };
    }
};

fn initialize(loading: Loading) Loading {
    const validated = loading.validated;
    return .{ .initialized = .{
        .loader = validated.loader,
        .image = validated.image,
        .descriptor = validated.descriptor,
    } };
}

fn publish(loading: Loading) error{OutOfMemory}!Loading {
    var initialized = loading.initialized;
    const owner = initialized.loader.owner();
    const state_value = owner.state().host.allocator().create(InstanceState) catch |err| {
        initialized.descriptor.deinit();
        initialized.image.close();
        return err;
    };
    state_value.* = .{
        .host = owner.state().host,
        .owner = owner,
        .image = initialized.image,
        .descriptor = initialized.descriptor,
    };
    _ = owner.state().live_instances.fetchAdd(1, .monotonic);
    return .{ .published = @ptrCast(state_value) };
}

const InstanceState = struct {
    host: *const heap.HostCleanup,
    owner: *Owner,
    refs: std.atomic.Value(u32) = .init(1),
    image: ImagePin,
    descriptor: *descriptor_api.ValidatedDescriptor,
    invocation_count: std.atomic.Value(u64) = .init(0),
    total_nanoseconds: std.atomic.Value(u64) = .init(0),
    overrun_count: std.atomic.Value(u64) = .init(0),
    diagnostic_emitted: std.atomic.Value(bool) = .init(false),
    retired_next: ?*InstanceState = null,
};

/// Nominal code-image and validated-metadata pin. Bindings can retain/release
/// it but cannot reach a loader handle, allocator, or reclamation domain.
pub const ModuleInstance = opaque {
    fn state(self: *const ModuleInstance) *const InstanceState {
        return @ptrCast(@alignCast(self));
    }

    fn mutableState(self: *ModuleInstance) *InstanceState {
        return @ptrCast(@alignCast(self));
    }

    pub fn retain(self: *ModuleInstance) void {
        const prior = self.mutableState().refs.fetchAdd(1, .monotonic);
        std.debug.assert(prior != 0 and prior != std.math.maxInt(u32));
    }

    pub fn retainCall(self: *ModuleInstance) bool {
        if (self.mutableState().owner.state().phase.load(.acquire) != .open) return false;
        self.retain();
        if (self.mutableState().owner.state().phase.load(.acquire) == .open) return true;
        self.releasePin();
        return false;
    }

    /// Releases one image pin. Reaching the final pin performs only an O(1)
    /// intrusive enqueue; descriptor destruction and dlclose require the
    /// Session-owned `Owner.settle` authority.
    pub fn releasePin(self: *ModuleInstance) void {
        const state_value = self.mutableState();
        const prior = state_value.refs.fetchSub(1, .release);
        std.debug.assert(prior != 0);
        if (prior != 1) return;
        _ = state_value.refs.load(.acquire);
        state_value.owner.enqueueRetired(state_value);
    }

    pub fn definitionCount(self: *const ModuleInstance) usize {
        return self.state().descriptor.definitions().len;
    }

    pub fn definition(
        self: *const ModuleInstance,
        index: u32,
    ) *const descriptor_api.ValidatedDefinition {
        return &self.state().descriptor.definitions()[index];
    }

    pub fn invoke(self: *const ModuleInstance) abi.Invoke {
        return self.state().descriptor.invoke();
    }

    pub fn requirements(self: *const ModuleInstance) []const abi.CapabilityRequirement {
        return self.state().descriptor.requirements();
    }

    pub fn hasCapability(self: *const ModuleInstance, id: abi.CapabilityId) bool {
        for (self.requirements()) |requirement|
            if (requirement.id == @intFromEnum(id)) return true;
        return false;
    }

    /// Derives the only host surface passed to this instance. Optional wire
    /// operations stay null unless descriptor validation granted the matching
    /// capability.
    pub fn mintHostTable(self: *const ModuleInstance, full: abi.HostTable) abi.HostTable {
        var result = full;
        if (!self.hasCapability(.ports)) result.port = null;
        if (!self.hasCapability(.build_values)) {
            result.build_list_append = null;
            result.build_list_finish = null;
            result.build_dict_append = null;
            result.build_dict_finish = null;
        }
        if (!self.hasCapability(.reschedule)) {
            result.continuation_state = null;
            result.consume = null;
            result.request_yield = null;
            result.list_at = null;
            result.dict_at = null;
            result.read_path = null;
            result.forward_path = null;
        }
        return result;
    }

    pub fn name(self: *const ModuleInstance) intern.ModuleName {
        return self.state().descriptor.name();
    }

    pub fn validated(self: *const ModuleInstance) *const descriptor_api.ValidatedDescriptor {
        return self.state().descriptor;
    }

    pub fn recordDuration(self: *ModuleInstance, nanoseconds: u64) bool {
        _ = self.mutableState().invocation_count.fetchAdd(1, .monotonic);
        _ = self.mutableState().total_nanoseconds.fetchAdd(nanoseconds, .monotonic);
        if (nanoseconds < 10 * std.time.ns_per_ms) return false;
        _ = self.mutableState().overrun_count.fetchAdd(1, .monotonic);
        return self.mutableState().diagnostic_emitted.cmpxchgStrong(
            false,
            true,
            .acq_rel,
            .acquire,
        ) == null;
    }
};

const OwnerState = struct {
    host: *const heap.HostCleanup,
    phase: std.atomic.Value(OwnerPhase) = .init(.open),
    live_instances: std.atomic.Value(u32) = .init(0),
    retired_mutex: std.Io.Mutex = .init,
    retired_first: ?*InstanceState = null,
    retired_last: ?*InstanceState = null,
};

const OwnerPhase = enum(u8) { open, closing, settled };

/// Session-owned factory and intrusive instance root. Worker-visible code can
/// load/adopt instances but cannot close the host reclamation root.
pub const Owner = opaque {
    fn state(self: *Owner) *OwnerState {
        return @ptrCast(@alignCast(self));
    }

    pub fn init(host: *const heap.HostCleanup) error{OutOfMemory}!*Owner {
        const state_value = try host.allocator().create(OwnerState);
        state_value.* = .{ .host = host };
        return ownerFromState(state_value);
    }

    /// Derives the only native-image capability inherited by worker Units.
    /// Its surface can open/validate an image but cannot settle or destroy the
    /// Session-owned reclamation root.
    pub fn loader(self: *Owner) *Loader {
        return @ptrCast(self);
    }

    /// First phase of Session shutdown. Once closed, no loader can mint a new
    /// image lifetime while the scheduler is joining existing transactions.
    pub fn closeCalls(self: *Owner) *ClosingOwner {
        const prior = self.state().phase.cmpxchgStrong(
            .open,
            .closing,
            .acq_rel,
            .acquire,
        );
        std.debug.assert(prior == null);
        return @ptrCast(self);
    }

    fn enqueueRetired(self: *Owner, instance: *InstanceState) void {
        const owner_state = self.state();
        std.Io.Threaded.mutexLock(&owner_state.retired_mutex);
        std.debug.assert(instance.retired_next == null);
        if (owner_state.retired_last) |last|
            last.retired_next = instance
        else
            owner_state.retired_first = instance;
        owner_state.retired_last = instance;
        std.Io.Threaded.mutexUnlock(&owner_state.retired_mutex);
    }

    fn popRetired(self: *Owner) ?*InstanceState {
        const owner_state = self.state();
        std.Io.Threaded.mutexLock(&owner_state.retired_mutex);
        defer std.Io.Threaded.mutexUnlock(&owner_state.retired_mutex);
        const instance = owner_state.retired_first orelse return null;
        owner_state.retired_first = instance.retired_next;
        if (owner_state.retired_first == null) owner_state.retired_last = null;
        instance.retired_next = null;
        return instance;
    }
};

/// Worker-visible image loading authority. It deliberately lacks owner
/// settlement and destruction operations.
pub const Loader = opaque {
    fn state(self: *Loader) *OwnerState {
        return @ptrCast(@alignCast(self));
    }

    fn owner(self: *Loader) *Owner {
        return @ptrCast(self);
    }

    pub fn startDynamic(
        self: *Loader,
        requested: intern.ModuleName,
        path: []const u8,
    ) error{OutOfMemory}!StartResult {
        if (self.state().phase.load(.acquire) != .open) return .{ .failure = .init(
            "native module loading is closed during Session shutdown",
            .{},
        ) };
        if (comptime !supported_platform) return .{ .failure = .init(
            "native module `{s}` is authoritative but dynamic loading requires the system loader (and a dynamically linked libc host on Linux)",
            .{path},
        ) };
        const terminated = try self.state().host.allocator().dupeZ(u8, path);
        defer self.state().host.allocator().free(terminated);
        var library = std.DynLib.openZ(terminated.ptr) catch |err| return .{ .failure = .init(
            "cannot open native module `{s}`: {s}; opening a native library executes arbitrary trusted code before ECL can inspect its descriptor",
            .{ path, @errorName(err) },
        ) };
        const entry = library.lookup(abi.EntryFn, abi.entry_symbol) orelse {
            library.close();
            return .{ .failure = .init(
                "native module `{s}` is missing entry symbol `{s}`",
                .{ path, abi.entry_symbol },
            ) };
        };
        return self.startOpened(.{ .opened = .{
            .loader = self,
            .requested = requested,
            .image = .{ .dynamic = library },
            .entry = entry,
        } });
    }

    pub fn startStatic(
        self: *Loader,
        requested: intern.ModuleName,
        descriptor: *const abi.Descriptor,
    ) StartResult {
        if (self.state().phase.load(.acquire) != .open) return .{ .failure = .init(
            "static native module loading is closed during Session shutdown",
            .{},
        ) };
        return self.startDescribed(.{ .described = .{
            .loader = self,
            .requested = requested,
            .image = .static,
            .descriptor = descriptor,
        } });
    }

    fn startOpened(self: *Loader, loading: Loading) StartResult {
        var opened = loading.opened;
        var entry_result = abi.EntryResult{ .status = .fail };
        opened.entry(&entry_result);
        if (entry_result.size != @sizeOf(abi.EntryResult)) {
            opened.image.close();
            return .{ .failure = .init(
                "native module entry failed: invalid result record size",
                .{},
            ) };
        }
        const accepted = switch (entry_result.status) {
            .descriptor => entry_result.descriptor != null,
            .fail => false,
            _ => false,
        };
        if (!accepted) {
            // The message can point into the image. Materialize the owned
            // diagnostic before closing that image on platforms that unload.
            const failure: LoadFailure = if (entry_result.message_ptr) |pointer|
                if (descriptor_api.guestUtf8(
                    pointer,
                    entry_result.message_len,
                    abi.max_error_message_bytes,
                )) |message|
                    .init("native module entry failed: {s}", .{message})
                else |_|
                    .init(
                        "native module entry failed: entry point returned no valid UTF-8 diagnostic",
                        .{},
                    )
            else
                .init("native module entry failed: entry point returned no descriptor", .{});
            opened.image.close();
            return .{ .failure = failure };
        }
        return self.startDescribed(.{ .described = .{
            .loader = opened.loader,
            .requested = opened.requested,
            .image = opened.image,
            .descriptor = entry_result.descriptor.?,
        } });
    }

    fn startDescribed(self: *Loader, loading: Loading) StartResult {
        const described = loading.described;
        return .{ .loading = .init(
            self,
            described.requested,
            described.image,
            described.descriptor,
        ) };
    }
};

/// Consumed Session shutdown authority. Only `Owner.closeCalls` can mint it,
/// after new call/image creation has been closed.
pub const ClosingOwner = opaque {
    fn owner(self: *ClosingOwner) *Owner {
        return @ptrCast(self);
    }

    pub fn settle(self: *ClosingOwner) *SettledOwner {
        const owner_value = self.owner();
        std.debug.assert(owner_value.state().phase.load(.acquire) == .closing);
        while (owner_value.popRetired()) |instance| {
            const allocator = instance.host.allocator();
            instance.descriptor.deinit();
            instance.image.close();
            allocator.destroy(instance);
            const prior = owner_value.state().live_instances.fetchSub(1, .release);
            std.debug.assert(prior != 0);
        }
        std.debug.assert(owner_value.state().live_instances.load(.acquire) == 0);
        owner_value.state().phase.store(.settled, .release);
        return @ptrCast(self);
    }
};

/// Final Session-only owner capability. No image lifetime can be created or
/// retired when this value is available.
pub const SettledOwner = opaque {
    pub fn deinit(self: *SettledOwner) void {
        const state_value: *OwnerState = @ptrCast(@alignCast(self));
        std.debug.assert(state_value.phase.load(.acquire) == .settled);
        const allocator = state_value.host.allocator();
        allocator.destroy(state_value);
    }
};

fn ownerFromState(state_value: *OwnerState) *Owner {
    return @ptrCast(state_value);
}

pub fn capabilityName(id: u32) []const u8 {
    return switch (@as(abi.CapabilityId, @enumFromInt(id))) {
        .call => "call",
        .build_values => "build-values",
        .reschedule => "reschedule",
        .ports => "ports",
        _ => "unknown",
    };
}
