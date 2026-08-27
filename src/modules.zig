//! Per-session module registry with typed names and atomic generation publication.
const std = @import("std");
const builtin = @import("builtin");
const env = @import("env.zig");
const value = @import("value.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const native_module = @import("native_module.zig");
const poll = @import("poll.zig");
const snapshot_api = @import("snapshot.zig");
const list = @import("list.zig");
const kernel_storage = @import("kernel_storage.zig");
const poll_api = @import("poll.zig");

/// Acquires one reference on a refcounted module owner, but only if a
/// reference already exists.
///
/// A scope cell names its owner without holding it, so a borrow that has just
/// read the cell may be racing that owner's last `release`. An unconditional
/// `fetchAdd` there asserts in a safe build and resurrects a destroyed object
/// in ReleaseFast. Failure leaves the count untouched, which is the load-
/// bearing half: a `fetchAdd` followed by a correction would publish a
/// transient nonzero value that a concurrent `release` could read as a live
/// owner.
fn tryAcquire(refs: *std.atomic.Value(u32)) bool {
    var observed = refs.load(.acquire);
    while (observed != 0) {
        std.debug.assert(observed != std.math.maxInt(u32));
        observed = refs.cmpxchgWeak(observed, observed + 1, .acq_rel, .acquire) orelse
            return true;
    }
    return false;
}

test "modules: a conditional acquire refuses a dead owner and never disturbs its count" {
    var live: std.atomic.Value(u32) = .init(1);
    try std.testing.expect(tryAcquire(&live));
    try std.testing.expectEqual(@as(u32, 2), live.load(.acquire));
    try std.testing.expect(tryAcquire(&live));
    try std.testing.expectEqual(@as(u32, 3), live.load(.acquire));

    // Zero is the point of no return: `release` has already cleared the label
    // cell and handed the owner to its release domain, so an acquire that
    // succeeded here would resurrect it.
    var dead: std.atomic.Value(u32) = .init(0);
    try std.testing.expect(!tryAcquire(&dead));
    try std.testing.expectEqual(@as(u32, 0), dead.load(.acquire));
    try std.testing.expect(!tryAcquire(&dead));
    try std.testing.expectEqual(@as(u32, 0), dead.load(.acquire));
}

/// One image's authoritative reference count, allocated with the image and
/// outliving it whenever a scope cell still names it.
///
/// Allocated at the image's birth, not at its first stamp: a refcount cannot
/// migrate mid-life without briefly existing twice, and two counts have a
/// window in which they disagree. One count, one retain/release path.
///
/// `image` dangles once the image has been destroyed. That is sound rather than
/// merely tolerated: it is read only after a successful `tryAcquire`, which
/// cannot succeed at zero, and zero is reached before the image is destroyed.
///
/// Only the anchor is parked at retirement, never the image. Parking the image
/// struct in place was implemented and measured against the retention soaks:
/// 394 bytes per stamped reload, large_growth=629952 against a bound of 226876
/// — 25x over. An anchor is cell-order instead, which those soaks tolerate.
const RefAnchor = struct {
    refs: std.atomic.Value(u32) = .init(1),
    park: Park,

    /// The image pointer and the parked-list link share one word, because a
    /// dead anchor's image pointer is never read again.
    ///
    /// That is a proof, not a hope. `image` is read only after a successful CAS
    /// off a nonzero count; `refs == 0` is permanent once reached; and `next` is
    /// stored on the release path strictly after zero. So a `tryRetain` racing
    /// the overlay fails its CAS and touches nothing else.
    ///
    /// The overlay is what brings the anchor to 16 bytes. It was measured
    /// against the retention soaks, which allow roughly 32 bytes per stamped
    /// reload: parking the whole `ModuleImage` in place cost 394 bytes and
    /// failed by 14212, and a 32-byte anchor would have cleared the bound by
    /// only 636 bytes against ~111KB of small-phase noise, which is how an
    /// invariant becomes a flaky test and then a weakened one.
    /// `extern` so it carries no safety tag. A plain untagged union is 16
    /// bytes in Debug and ReleaseSafe because Zig adds one, which alone would
    /// blow the 16-byte anchor budget -- measured, not assumed. Both members are
    /// plain pointers, so extern layout is exact and the link is the node: a
    /// `TombstoneNode` is nothing but its `next`, so a pointer to this union
    /// *is* a pointer to the node.
    const Park = extern union {
        image: *ModuleImage,
        next: ?*heap.ReleaseDomain.TombstoneNode,
    };

    fn tryRetain(self: *RefAnchor) bool {
        return tryAcquire(&self.refs);
    }
};

comptime {
    if (@sizeOf(RefAnchor) > 16)
        @compileError("RefAnchor exceeds the parked-anchor budget the retention soaks impose");
}

/// Whether two homes execute the same image, compared by anchor. Used to decide
/// whether a module-local hit came out of the image the activation is running or
/// out of a foreign one.
pub fn sameImage(
    left: *const ModuleHome,
    right: *const ModuleHome,
    _: *const ExecutionAccess,
) bool {
    return anchorHandleInternal(left) == anchorHandleInternal(right);
}

/// The opaque handle a scope cell stores to name this image's anchor.
///
/// The cell must name the *anchor* and not the home: a home is embedded in the
/// image, and the anchor is precisely the thing that outlives it. So
/// `ModuleHome.tryPin` cannot serve a cell-originated borrow, and
/// `tryPinAnchor` below is its counterpart for one.
pub fn anchorHandle(home: *const ModuleHome, _: *const ExecutionAccess) *anyopaque {
    return anchorHandleInternal(home);
}

fn anchorHandleInternal(home: *const ModuleHome) *anyopaque {
    return @ptrCast(home.state().image.anchor);
}

fn tryPinAnchorInternal(owner: *anyopaque) ?GenerationPin {
    const anchor: *RefAnchor = @ptrCast(@alignCast(owner));
    if (!anchor.tryRetain()) return null;
    // Only now is the image pointer readable: before the CAS succeeded this
    // word may have been the parked-list link instead.
    return .initRetained(&anchor.park.image.construction_home);
}

/// Acquires one reference through a scope cell's owner handle, or null when the
/// image has reached its last release.
///
/// Split from `tryPinAnchorInternal` for the same reason `pin` is split from
/// `pinInternal`: the audit rejects one function that both holds a capability
/// token and casts a pointer.
pub fn tryPinAnchor(owner: *anyopaque, _: *const ExecutionAccess) ?GenerationPin {
    return tryPinAnchorInternal(owner);
}

/// The single destructor `ReleaseDomain.reclaimTombstones` is given.
///
/// A parked anchor is the only thing this module ever parks. A second parked
/// type must take its own list head rather than turn the node into a
/// discriminated one -- the node is a bare link precisely because the soak
/// budget has no room for discrimination.
pub fn destroyParkedAnchor(
    allocator: std.mem.Allocator,
    node: *heap.ReleaseDomain.TombstoneNode,
) void {
    // The link is the union's first and only field, so the union starts where
    // the node does. Plain casts, no capability token.
    const park: *RefAnchor.Park = @ptrCast(node);
    const anchor: *RefAnchor = @fieldParentPtr("park", park);
    allocator.destroy(anchor);
}

/// The execution identity of module code: which image is running, and — when
/// the code was reached through the registry — which registration owns its
/// name, durable state, and lifetime. A construction root has no registration,
/// which is what makes `within` structurally impossible while a body is still
/// building its image.
const ExecutionHome = struct {
    image: *ModuleImage,
    registration: ?*Registration,

    fn retain(self: *const ExecutionHome) void {
        if (self.registration) |registration| registration.retain() else self.image.retain();
    }
    fn release(self: *const ExecutionHome) void {
        if (self.registration) |registration| registration.release() else self.image.release();
    }
    /// The failable counterpart, for a caller that reached this home through a
    /// scope cell rather than through a reference it already holds. An
    /// anonymous image has no registration and is covered by the same call,
    /// which is why the deleted publisher-lease protocol could not serve here.
    fn tryRetain(self: *const ExecutionHome) bool {
        return if (self.registration) |registration|
            registration.tryRetain()
        else
            self.image.tryRetain();
    }
};

/// The immutable content of a module: the frozen environment its definitions
/// live in, the module-root scope they were published through, and the
/// construction body's final operand stack as an initial-state template.
///
/// An image owns no canonical name, registry slot, arbiter, generation
/// currency, or `SlotLease`. That absence is the whole point: it lets one
/// image back several independent registrations, and it keeps the value heap a
/// DAG, because a registration retains an image and never the reverse.
const ModuleImage = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    environment: env.Environment,
    scope: env.Scope,
    /// The construction body's final operand stack, bottom first. A first
    /// registration copies it into that slot's durable stack and a
    /// re-registration discards it for that slot; entries are scalars until
    /// the capture fills them, so every element is releasable at any point.
    initial_state: []value.Value = &.{},
    /// The registration-free home. Its registration is null, so no state
    /// application can open against it — which is what a module still being
    /// built needs, and equally what an image reached as a value needs, since
    /// neither owns a slot. It embeds a pointer to its own owner, so `create`
    /// fills it in after the allocation rather than defaulting it.
    construction_home: ExecutionHome,
    /// The authoritative count lives here, not inline, so it can outlive this
    /// struct for the images a scope cell names.
    anchor: *RefAnchor,
    /// Whether ECL source was ever stamped against this image, recorded where
    /// `release` takes the label cell. Only a stamped image is named by a cell
    /// that holds no reference, so only a stamped image's anchor is parked.
    minted_cell: bool = false,
    retirement: heap.ReleaseDomain.Retirement = .{},
    retirement_state: union(enum) {
        live,
        template: usize,
        scope: env.Scope.EmbeddedTeardownCursor,
        environment: env.Environment.TeardownCursor,
    } = .live,

    fn create(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
    ) error{OutOfMemory}!*ModuleImage {
        // No scope cell is minted here. An image needs one only if ECL source
        // is stamped against it, which `moduleOwned` arranges lazily; a registry
        // -level registration publishes definitions directly and stamps
        // nothing, so minting here would grow live memory with every
        // re-registration for a cell no word ever names.
        const result = try allocator.create(ModuleImage);
        const anchor = allocator.create(RefAnchor) catch |err| {
            allocator.destroy(result);
            return err;
        };
        anchor.* = .{ .park = .{ .image = result } };
        result.allocator = allocator;
        result.anchor = anchor;
        result.minted_cell = false;
        result.environment = env.Environment.init(allocator, releases);
        result.scope = env.Scope.moduleRoot(allocator, &result.environment);
        result.initial_state = &.{};
        result.construction_home = .{ .image = result, .registration = null };
        result.retirement = .{};
        result.retirement_state = .live;
        return result;
    }

    fn retain(self: *ModuleImage) void {
        const old = self.anchor.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old != 0 and old != std.math.maxInt(u32));
    }

    /// Reachable only from a caller that already holds this image alive, since
    /// the home it goes through is embedded in the image. A borrow that starts
    /// from a scope cell must acquire the *anchor* directly instead: the cell
    /// outlives the image, so routing through the image would dereference
    /// freed memory to find the count.
    fn tryRetain(self: *ModuleImage) bool {
        return self.anchor.tryRetain();
    }

    fn release(self: *ModuleImage) void {
        const old = self.anchor.refs.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old != 1) return;
        _ = self.anchor.refs.load(.acquire);
        // Before any teardown step, so a quotation labelled with this image
        // reads a definite `retired` and never a scope under teardown. The
        // embedded scope's own teardown takes the cell with the same swap, so
        // exactly one of the two paths drops the owner reference.
        if (self.scope.label_cell.swap(null, .acq_rel)) |cell| {
            cell.retire();
            // A cell outlives this image and names its anchor without holding
            // a reference, so the anchor must survive the image.
            self.minted_cell = true;
        }
        self.retirement_state = if (self.initial_state.len == 0)
            .{ .scope = .init(&self.scope) }
        else
            .{ .template = self.initial_state.len };
        self.environment.releases.retire(self, &self.retirement);
    }

    /// The heap's module value calls this on final release; whatever the drop
    /// makes unreachable retires through the same domain in later steps.
    pub fn releaseImage(self: *ModuleImage) void {
        self.release();
    }

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *ModuleImage,
    ) bool {
        return switch (self.retirement_state) {
            .live => unreachable,
            .template => |remaining| {
                releases.releaseValue(self.initial_state[remaining - 1]);
                if (remaining != 1) {
                    self.retirement_state = .{ .template = remaining - 1 };
                    return false;
                }
                allocator.free(self.initial_state);
                self.initial_state = &.{};
                self.retirement_state = .{ .scope = .init(&self.scope) };
                return false;
            },
            .scope => |*scope| result: {
                if (!scope.advance()) break :result false;
                self.retirement_state = .{ .environment = .init(&self.environment) };
                break :result false;
            },
            .environment => |*environment| {
                if (!environment.advance()) return false;
                // The image is destroyed in full, exactly as before: contents,
                // embedded Environment and Scope, and the allocation. Only the
                // anchor's fate is conditional.
                const anchor = self.anchor;
                const stamped = self.minted_cell;
                allocator.destroy(self);
                if (!stamped) {
                    // Nothing ever named this image, so nothing can observe the
                    // anchor going away. This is the path every registry-level
                    // registration takes.
                    allocator.destroy(anchor);
                    return true;
                }
                // `refs` stays readable and CAS-able at zero, so a borrow that
                // reaches this anchor from a scope cell fails its acquire
                // rather than faulting. Freed by the host walk at the end of
                // `Session.deinit`: valid until the final host teardown walk,
                // which runs after execution has provably stopped, because
                // `scheduler.deinit` is the first thing that teardown does.
                // The image is gone, so its pointer in the anchor is dead
                // space; the parked link takes that word.
                anchor.park = .{ .next = null };
                releases.parkTombstone(@ptrCast(&anchor.park));
                return true;
            },
        };
    }
};

/// One published code generation of one canonical name. It retains the image
/// it publishes and owns everything the image deliberately does not: the name,
/// the generation number, and the slot lifetime witness that keeps the durable
/// state and arbiter reachable while old code can still name them.
const Registration = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    /// One retained image reference held for this generation's whole lifetime.
    image: *ModuleImage,
    name: intern.ModuleName,
    generation: u64 = 0,
    /// A provisional registration exists only inside a publication cursor and
    /// is never reachable as a home, which makes `within` at registration
    /// time structurally impossible. Publication installs an owned lifetime
    /// witness that stays with this generation through supersession and
    /// delayed retirement, so slot storage cannot be recycled while old code
    /// can still name it.
    slot_lifetime: union(enum) {
        provisional,
        published: SlotLease,
    } = .provisional,
    /// The execution home callers reach this registration through. Like the
    /// image's, it embeds a pointer to its own owner and is therefore filled in
    /// after the allocation.
    home: ExecutionHome,
    retirement: heap.ReleaseDomain.Retirement = .{},

    /// Retains `image` on success; on failure the caller still owns its own
    /// reference and nothing was retained.
    fn create(
        allocator: std.mem.Allocator,
        image: *ModuleImage,
        name: intern.ModuleName,
    ) error{OutOfMemory}!*Registration {
        const result = try allocator.create(Registration);
        image.retain();
        result.allocator = allocator;
        result.refs = .init(1);
        result.image = image;
        result.name = name;
        result.generation = 0;
        result.slot_lifetime = .provisional;
        result.home = .{ .image = image, .registration = result };
        result.retirement = .{};
        return result;
    }

    fn retain(self: *Registration) void {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old != 0 and old != std.math.maxInt(u32));
    }

    /// Failable, for the same reason as `ModuleImage.tryRetain`: a home reached
    /// through a scope cell is not yet held, so the count may already be zero.
    fn tryRetain(self: *Registration) bool {
        return tryAcquire(&self.refs);
    }

    fn release(self: *Registration) void {
        const old = self.refs.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old != 1) return;
        _ = self.refs.load(.acquire);
        self.image.environment.releases.retire(self, &self.retirement);
    }

    /// Constant time: the lease and the image reference each drop by one, and
    /// the image's own user-sized graph retires as separate bounded work.
    pub fn advanceRetirement(
        _: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *Registration,
    ) bool {
        switch (self.slot_lifetime) {
            .provisional => {},
            .published => |*lease| lease.deinit(),
        }
        self.image.release();
        allocator.destroy(self);
        return true;
    }

    pub const ResolveProgress = poll.Progress(?env.BindingLease);
    /// Export lookup is always public-only: a private is absent from a
    /// module's public face, and no caller has ever wanted otherwise.
    pub const ResolveCursor = struct {
        allocator: std.mem.Allocator,
        lookup: env.DirectLookupCursor,
        pin: GenerationPin,

        pub fn deinit(self: *ResolveCursor) void {
            self.lookup.deinit();
            self.pin.deinit();
            self.* = undefined;
        }
        pub fn advance(self: *ResolveCursor) ResolveProgress {
            return switch (self.lookup.advance()) {
                .pending => .pending,
                .complete => |maybe_lease| result: {
                    var lease = maybe_lease orelse break :result .{ .complete = null };
                    if (lease.visibility == .private) {
                        lease.deinit();
                        break :result .{ .complete = null };
                    }
                    break :result .{ .complete = lease };
                },
            };
        }
    };
    pub fn resolveCursor(self: *const Registration, id: u32) ResolveCursor {
        return resolveCursorFor(self.image, ModuleHome.init(&@constCast(self).home), id);
    }

    pub const PublicNameProgress = poll.StreamProgress(u32);
    pub const PublicNameCursor = struct {
        allocator: std.mem.Allocator,
        inner: env.NameCursor,
        pin: GenerationPin,
        pub fn deinit(self: *PublicNameCursor) void {
            self.inner.deinit();
            self.pin.deinit();
            self.* = undefined;
        }
        pub fn advance(self: *PublicNameCursor) PublicNameProgress {
            return switch (self.inner.advance()) {
                .pending => .pending,
                .complete => .complete,
                .item => |entry| result: {
                    var lease = entry.lease;
                    defer lease.deinit();
                    break :result if (lease.visibility == .public)
                        .{ .item = entry.name }
                    else
                        .pending;
                },
            };
        }
    };
    pub fn publicNameCursor(self: *const Registration) PublicNameCursor {
        const home = ModuleHome.init(&@constCast(self).home);
        return .{
            .allocator = self.allocator,
            .inner = self.image.environment.nameCursor(),
            .pin = home.pinInternal(),
        };
    }
};

/// Fair per-slot ordering of state applications. Waiters are granted in
/// arrival order and the granted turn is always the queue head, so both
/// grant and release are O(1) and no waiter can be starved by a later one.
const Arbiter = struct {
    mutex: std.Io.Mutex = .init,
    head: ?*StateTurn = null,
    tail: ?*StateTurn = null,
    /// Whether the head has taken the slot. Grants live here rather than on
    /// each waiting turn, so nothing a second thread writes is ever read
    /// outside this mutex.
    active: bool = false,
};

/// The durable-state owner behind a live module home. Obtaining one proves
/// the executing code is homed in a committed slot; it grants nothing by
/// itself, because reading and publishing both additionally require a
/// granted turn.
/// The slot behind an executing home, or null when the home is an
/// uncommitted candidate: a registration root operates directly on its
/// construction stack and can never open a state application.
/// Whether every turn that could still touch this slot's arbiter has
/// unlinked. A retired slot's queue drains on its own: admission is closed,
/// so each waiter that is granted discovers a superseded home and releases.
fn arbiterQuiescent(owning: *ModuleSlot) bool {
    std.Io.Threaded.mutexLock(&owning.arbiter.mutex);
    defer std.Io.Threaded.mutexUnlock(&owning.arbiter.mutex);
    return owning.arbiter.head == null and !owning.arbiter.active;
}

/// Closes admission from inside the arbiter lock, so no turn can be queued
/// after the owner decides to remove the slot.
fn closeArbiter(owning: *ModuleSlot) void {
    std.Io.Threaded.mutexLock(&owning.arbiter.mutex);
    defer std.Io.Threaded.mutexUnlock(&owning.arbiter.mutex);
    owning.phase.store(.closing, .release);
}

fn registrationSlot(registration: *const Registration) ?*ModuleSlot {
    return switch (registration.slot_lifetime) {
        .provisional => null,
        .published => |lease| lease.slot(),
    };
}

/// The slot behind an executing home, or null when the home is a construction
/// root: an anonymous image has no registration, so it has no durable state to
/// open a transaction against.
fn homeSlot(home: *const ModuleHome) ?*ModuleSlot {
    return registrationSlot(home.state().registration orelse return null);
}

/// Retains the published generation's slot witness. The returned capability
/// crosses the gap between inspecting a home and joining the slot arbiter;
/// callers never carry an unprotected slot pointer through that gap.
pub fn retainHomeSlot(home: *const ModuleHome, _: *const ExecutionAccess) ?SlotLease {
    const registration = home.state().registration orelse return null;
    return switch (registration.slot_lifetime) {
        .provisional => null,
        .published => |lease| lease.clone(),
    };
}

/// Whether the executing home is still its slot's current code generation.
/// Old code keeps running under its pin exactly as it always has, but it may
/// not publish state once a replacement representation is current.
pub fn homeIsCurrent(home: *const ModuleHome, _: *const ExecutionAccess) bool {
    const registration = home.state().registration orelse return false;
    const owning = registrationSlot(registration) orelse return false;
    return owning.publisher.isCurrent(registration);
}

/// One place in a slot's fair FIFO, and the only capability that authorizes
/// reading or replacing the durable stack. It is requested once, granted at
/// most once, and released exactly once; publication is legal only while
/// granted, which makes the durable stack single-writer without holding a
/// lock while ECL code runs.
/// A unit's single right to hold one module slot's turn.
///
/// Requesting a turn consumes it and releasing returns it, so "already
/// inside a state application" stops being a condition three call sites
/// have to remember to check. A nested `within`, a draft on a second
/// module, and a reload or removal issued from inside a state application
/// are all the same thing — a second request with nothing left to spend —
/// and the compiler makes every acquisition site handle it.
pub const TurnAuthority = enum(u8) { available, spent };

pub const StateTurn = struct {
    lease: SlotLease,
    authority: union(enum) {
        unit: *TurnAuthority,
        detached,
    },
    previous: ?*StateTurn = null,
    next: ?*StateTurn = null,
    /// Owner-thread only. `linked` says whether the arbiter still holds this
    /// node; `holding` mirrors a grant this thread already observed under
    /// the arbiter mutex, so reading or publishing the durable stack needs
    /// no second acquisition. The arbiter owns the grant itself — a turn
    /// carries no shared typestate of its own to read unlocked.
    linked: bool = false,
    holding: bool = false,

    pub const RequestError = error{
        /// The unit already holds a turn on some slot.
        StateApplicationActive,
        /// The owner closed before this request reached the arbiter.
        ModuleRemoved,
    };

    /// An unrequested turn owns nothing: no place in the queue and no
    /// authority. `request` is the only transition that changes that.
    pub fn init(lease: SlotLease, authority: *TurnAuthority) StateTurn {
        return .{ .lease = lease, .authority = .{ .unit = authority } };
    }

    pub fn sameSlot(self: *const StateTurn, home: *const ModuleHome, _: *const ExecutionAccess) bool {
        return homeSlot(home) == self.lease.slot();
    }

    /// Spends the unit's authority and joins the queue. Admission and the
    /// close edge share the arbiter lock, so a turn is never queued against
    /// a slot that is already closing.
    pub fn request(self: *StateTurn) RequestError!void {
        std.debug.assert(!self.linked and !self.holding);
        const authority = switch (self.authority) {
            .unit => |unit| unit,
            .detached => unreachable,
        };
        if (authority.* == .spent) return error.StateApplicationActive;
        const owning = self.lease.slot();
        const arbiter = &owning.arbiter;
        std.Io.Threaded.mutexLock(&arbiter.mutex);
        defer std.Io.Threaded.mutexUnlock(&arbiter.mutex);
        if (owning.phase.load(.acquire) != .live) return error.ModuleRemoved;
        self.previous = arbiter.tail;
        if (arbiter.tail) |tail| tail.next = self else arbiter.head = self;
        arbiter.tail = self;
        self.linked = true;
        authority.* = .spent;
    }

    /// Transfers a granted, closing-slot turn out of its Unit. The Unit gets
    /// its authority back immediately; subsequent retirement owns only the
    /// queue node and slot lease, never a pointer into Unit storage.
    fn detachUnitAuthority(self: *StateTurn) void {
        std.debug.assert(self.holding);
        const authority = switch (self.authority) {
            .unit => |unit| unit,
            .detached => unreachable,
        };
        std.debug.assert(authority.* == .spent);
        authority.* = .available;
        self.authority = .detached;
    }

    /// Whether this turn holds the slot. The grant lives in the arbiter, not
    /// in the node, so this is the only place it is read — under the mutex
    /// that is also the happens-before edge between the previous holder's
    /// publication and this holder's read of the durable stack.
    pub fn granted(self: *StateTurn) bool {
        if (self.holding) return true;
        std.debug.assert(self.linked);
        const arbiter = &self.lease.slot().arbiter;
        std.Io.Threaded.mutexLock(&arbiter.mutex);
        defer std.Io.Threaded.mutexUnlock(&arbiter.mutex);
        if (arbiter.active) {
            self.holding = arbiter.head == self;
        } else if (arbiter.head == self) {
            arbiter.active = true;
            self.holding = true;
        }
        return self.holding;
    }

    /// Leaves the queue and returns the unit's authority: a waiter unlinks
    /// without ever having run, and a holder hands the slot to its
    /// successor.
    pub fn release(self: *StateTurn) void {
        if (!self.linked) {
            self.lease.deinit();
            return;
        }
        const arbiter = &self.lease.slot().arbiter;
        {
            std.Io.Threaded.mutexLock(&arbiter.mutex);
            defer std.Io.Threaded.mutexUnlock(&arbiter.mutex);
            if (self.previous) |before| before.next = self.next else arbiter.head = self.next;
            if (self.next) |after| after.previous = self.previous else arbiter.tail = self.previous;
            if (arbiter.active and self.holding) arbiter.active = false;
            self.previous = null;
            self.next = null;
        }
        self.linked = false;
        self.holding = false;
        switch (self.authority) {
            .unit => |authority| authority.* = .available,
            .detached => {},
        }
        self.lease.deinit();
    }

    /// The durable stack, borrowed for the duration of this turn.
    pub fn stack(self: *const StateTurn) []const value.Value {
        std.debug.assert(self.holding);
        return self.lease.slot().state;
    }

    pub fn allocator(self: *const StateTurn) std.mem.Allocator {
        return self.lease.slot().allocator;
    }

    /// Installs a replacement durable stack and hands back the previous one
    /// for the caller to retire. This is the whole mutation surface.
    pub fn publish(self: *StateTurn, next: []value.Value) []value.Value {
        std.debug.assert(self.holding);
        const owning = self.lease.slot();
        const previous = owning.state;
        owning.state = next;
        return previous;
    }
};

const GenerationPublisher = snapshot_api.Publisher(Registration);

/// Nominal ownership of one permanent registry-inventory node. A slot keeps
/// this capability for its allocation lifetime, including while retired and
/// awaiting reuse, so removal never searches a mutable global container.
const InventoryEntry = enum(usize) {
    detached = 0,
    _,

    fn init(entry: *SlotEntry) InventoryEntry {
        return @enumFromInt(@intFromPtr(entry));
    }

    fn node(self: InventoryEntry) *SlotEntry {
        std.debug.assert(self != .detached);
        return @ptrFromInt(@intFromEnum(self));
    }
};

/// The internal state owner for one live registration. It spans every code
/// generation published before removal and solely owns that registration's
/// durable operand-stack snapshot; no ECL value exposes its identity, and its
/// storage may represent a later registration only after every witness drains.
const ModuleSlot = struct {
    publisher: GenerationPublisher = .init(null),
    inventory: InventoryEntry,
    /// Owned witnesses held by published generations, cursors, and
    /// arbiter turns. The registry owns the allocation itself; recycling is
    /// legal only after this count reaches zero.
    lease_refs: std.atomic.Value(u32) = .init(0),
    /// The registry allocator, kept on the slot so a granted turn can size a
    /// replacement stack without a second correlated capability.
    allocator: std.mem.Allocator,
    /// Fair FIFO ordering of state applications. It is held only for O(1)
    /// pointer surgery, never across ECL execution.
    arbiter: Arbiter = .{},
    /// The durable stack, bottom first. Initialized exactly once from the
    /// construction body and replaced only by transactional publication.
    state: []value.Value = &.{},
    /// The owner lifecycle. Removal and Session shutdown consume the same
    /// live -> closing -> retired transitions, and a retired slot owns
    /// nothing but its own struct.
    phase: std.atomic.Value(Phase) = .init(.live),

    /// Retired slots are recycled rather than freed. Resolution cursors reach
    /// a slot through a directory snapshot that removal may
    /// already have replaced, so the struct must stay valid memory for as
    /// long as the registry does; reuse is what keeps that bounded by peak
    /// simultaneously live slots instead of by registration history.
    next_recycled: ?*ModuleSlot = null,

    const Phase = enum(u8) { live, closing, retired };

    fn resetForReuse(self: *ModuleSlot) void {
        const inventory = self.inventory;
        const allocator = self.allocator;
        self.* = .{ .inventory = inventory, .allocator = allocator };
        std.debug.assert(inventory.node().slot == self);
    }

    /// Releases everything the slot owns exactly once, so removal and
    /// Session teardown can both reach it.
    fn retire(self: *ModuleSlot, releases: *heap.ReleaseDomain) void {
        if (self.phase.load(.acquire) == .retired) return;
        self.phase.store(.retired, .release);
        if (self.publisher.currentOwned()) |generation| {
            self.publisher.publish(null);
            generation.release();
        }
        for (self.state) |item| releases.releaseValue(item);
        if (self.state.len != 0) self.allocator.free(self.state);
        self.state = &.{};
    }

    /// Finish retirement after a detached worker has released every durable
    /// state value. This transition is constant-time and never walks payload.
    fn retireEmpty(self: *ModuleSlot) void {
        std.debug.assert(self.state.len == 0);
        if (self.phase.load(.acquire) == .retired) return;
        self.phase.store(.retired, .release);
        if (self.publisher.currentOwned()) |generation| {
            self.publisher.publish(null);
            generation.release();
        }
    }
};

/// An owned, nominal witness for one allocation of a module slot. Its
/// constructor is private to this file, and every copy is an explicit retain.
/// The consumed sentinel makes transfers visible in the implementation and
/// prevents an abandoned cursor from releasing the same witness twice.
const SlotLease = enum(usize) {
    consumed = 0,
    _,

    fn retain(slot_ptr: *ModuleSlot) SlotLease {
        const old = slot_ptr.lease_refs.fetchAdd(1, .monotonic);
        std.debug.assert(old != std.math.maxInt(u32));
        return @enumFromInt(@intFromPtr(slot_ptr));
    }

    fn slot(self: SlotLease) *ModuleSlot {
        std.debug.assert(self != .consumed);
        return @ptrFromInt(@intFromEnum(self));
    }

    fn clone(self: SlotLease) SlotLease {
        return retain(self.slot());
    }

    fn move(self: *SlotLease) SlotLease {
        const result = self.*;
        std.debug.assert(result != .consumed);
        self.* = .consumed;
        return result;
    }

    pub fn deinit(self: *SlotLease) void {
        if (self.* == .consumed) return;
        const owning = self.slot();
        const old = owning.lease_refs.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old == 1) _ = owning.lease_refs.load(.acquire);
        self.* = .consumed;
    }
};

const Directory = struct {
    const ModuleMap = poll.FixedMap(intern.ModuleName, *ModuleSlot);
    const AliasMap = poll.FixedMap(intern.BindingName, intern.ModuleName);

    modules: ModuleMap,
    aliases: AliasMap,
    previous: ?*Directory,
    retirement: heap.ReleaseDomain.Retirement = .{},

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *Directory,
    ) bool {
        const previous = self.previous;
        self.modules.deinit();
        self.aliases.deinit();
        allocator.destroy(self);
        if (previous) |next| releases.retire(next, &next.retirement);
        return true;
    }

    fn destroy(self: *Directory, allocator: std.mem.Allocator) void {
        self.modules.deinit();
        self.aliases.deinit();
        allocator.destroy(self);
    }

    fn destroyChain(first: ?*Directory, allocator: std.mem.Allocator) void {
        var cursor = first;
        while (cursor) |directory| {
            cursor = directory.previous;
            directory.destroy(allocator);
        }
    }
};
const DirectoryPublisher = snapshot_api.Publisher(Directory);

const DirectoryLease = struct {
    registry: *const Registry,
    lease: DirectoryPublisher.Lease,
    directory: ?*const Directory,

    fn deinit(self: *DirectoryLease) void {
        const registry = @constCast(self.registry);
        if (self.lease.deinit()) {
            registry.lockBlocking();
            const retired = registry.detachRetiredDirectories();
            registry.unlock();
            if (retired) |first| registry.releaseDomain().retire(first, &first.retirement);
        }
        self.* = undefined;
    }
};

/// Session-owned authority required to turn observation state into frame
/// execution state. Session and Unit storage own the seal; registered native
/// callbacks never receive it.
pub const ExecutionAccess = opaque {};

/// Narrow identity used by executing frames: the image that is running plus
/// the registration, if any, whose name and durable state it is running
/// against. Observation leases never expose this pointer; only code holding
/// the Session's execution authority can obtain its scope or another pin.
///
/// Because one image may be registered more than once, this — not anything in
/// the image or in a definition's metadata — is what selects private lookup,
/// same-home dispatch, diagnostic spelling, and `within`'s slot.
pub const ModuleHome = opaque {
    fn init(home_state: *ExecutionHome) *ModuleHome {
        return @ptrCast(home_state);
    }
    fn state(self: *const ModuleHome) *ExecutionHome {
        return @ptrCast(@alignCast(@constCast(self)));
    }
    pub fn scope(self: *const ModuleHome, _: *const ExecutionAccess) *env.Scope {
        return &self.state().image.scope;
    }
    /// The canonical name this activation was reached through, or null while a
    /// construction body is still building an anonymous image.
    pub fn name(self: *const ModuleHome) ?intern.ModuleName {
        const registration = self.state().registration orelse return null;
        return registration.name;
    }
    pub fn generationNumber(self: *const ModuleHome) u64 {
        const registration = self.state().registration orelse return 0;
        return registration.generation;
    }
    fn pinInternal(self: *const ModuleHome) GenerationPin {
        self.state().retain();
        return .initRetained(self.state());
    }
    pub fn pin(self: *const ModuleHome, _: *const ExecutionAccess) GenerationPin {
        return self.pinInternal();
    }
    fn tryPinInternal(self: *const ModuleHome) ?GenerationPin {
        if (!self.state().tryRetain()) return null;
        return .initRetained(self.state());
    }
    /// The pin a borrow takes. Null means this home's owner has reached its
    /// last release, which resolution reports as a retired scope rather than
    /// falling back to another chain. Split from `tryPinInternal` for the same
    /// reason `pin` is: the source audit rejects one function that both holds a
    /// capability token and performs a pointer cast.
    pub fn tryPin(self: *const ModuleHome, _: *const ExecutionAccess) ?GenerationPin {
        return self.tryPinInternal();
    }
};

/// An owned reference to whichever owner backs one home. The raw image or
/// registration is never exposed, so a pin can only be consumed by `deinit`
/// and cannot invoke retirement directly.
pub const GenerationPin = enum(usize) {
    consumed = 0,
    _,

    fn initRetained(retained: *ExecutionHome) GenerationPin {
        return @enumFromInt(@intFromPtr(retained));
    }
    fn home(self: GenerationPin) *ModuleHome {
        std.debug.assert(self != .consumed);
        return @ptrFromInt(@intFromEnum(self));
    }
    pub fn deinit(self: *GenerationPin) void {
        if (self.* == .consumed) return;
        self.home().state().release();
        self.* = .consumed;
    }
    /// Whether two pins hold the same owner. Exposes nothing: a pin is already
    /// an opaque integer, and this only compares two of them. It exists so a
    /// pin adopted from a borrow can be deduplicated against pins already held
    /// without anyone learning what it points at.
    pub fn sameOwner(self: GenerationPin, other: GenerationPin) bool {
        return @intFromEnum(self) == @intFromEnum(other);
    }

    pub fn matches(
        self: GenerationPin,
        expected_home: *const ModuleHome,
        _: *const ExecutionAccess,
    ) bool {
        return self.home() == expected_home;
    }
};

/// The registration-less home of the image a module-root scope belongs to, or
/// null for any other scope.
///
/// The cast is sound because `env.Scope.moduleRoot` has exactly one caller —
/// `ModuleImage.create` — so every module-root scope is an image's own embedded
/// `scope` field. Re-verified when this was written; a second caller would
/// falsify it, which is why the check belongs in review and not only here.
///
/// The home is deliberately registration-less: see `construction_home`. A word
/// reached through it therefore owns no slot, so `within` is `'domain` rather
/// than a write to whichever slot the caller happened to be running.
///
/// Takes no `ExecutionAccess`: the token gates `ModuleHome`'s methods, not the
/// pointer, and the audit rejects one function that both holds a token and
/// casts a pointer.
pub fn homeForModuleRootScope(scope: *env.Scope) ?*ModuleHome {
    if (!scope.isModuleRoot()) return null;
    const image: *ModuleImage = @fieldParentPtr("scope", scope);
    return ModuleHome.init(&image.construction_home);
}

test "modules: an image's registration-less home is reachable from its own root scope" {
    var host = heap.HostOwner.init(std.testing.allocator);
    const releases = host.domain();
    defer host.cleanup().drain();

    var container = try env.Env.init(&host);
    defer container.deinit();

    const image = try ModuleImage.create(std.testing.allocator, releases);
    defer image.release();

    const recovered = homeForModuleRootScope(&image.scope) orelse
        return error.ExpectedImageHome;
    try std.testing.expectEqual(ModuleHome.init(&image.construction_home), recovered);
    // Registration-less by construction. This is the whole reason the accessor
    // exists: it is what makes `within` through an escaped quotation a domain
    // error instead of a write to the caller's slot.
    try std.testing.expectEqual(@as(?intern.ModuleName, null), recovered.name());

    var session_scope = container.sessionRoot(std.testing.allocator);
    defer env.testing.deinitScope(&session_scope, releases);
    try std.testing.expectEqual(
        @as(?*ModuleHome, null),
        homeForModuleRootScope(&session_scope),
    );
}

test "modules: a stamped retired image leaves one anchor and an unstamped one leaves nothing" {
    // Registry-level rather than Session-level, and every sample is taken after
    // an explicit drain to quiescence. A Session-level version of this measured
    // 52KB per cycle against an expected 40 bytes: it was sampling deferred
    // retirement backlog, not settled memory. Absolute settled-memory bounds
    // are only assertable where the drains are controllable.
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var host = heap.HostOwner.init(allocator);
        const releases = host.domain();
        var container = try env.Env.init(&host);

        const rounds = 64;

        // An image nothing ever stamped is destroyed in full, anchor included.
        host.cleanup().drain();
        const unstamped_base = counting.total_requested_bytes;
        for (0..rounds) |_| {
            const image = try ModuleImage.create(allocator, releases);
            image.release();
            host.cleanup().drain();
        }
        try std.testing.expectEqual(
            @as(usize, 0),
            counting.total_requested_bytes -| unstamped_base,
        );

        // A stamped image mints its cell exactly as `moduleOwned` does, and
        // leaves precisely that cell plus its parked anchor behind.
        const stamped_base = counting.total_requested_bytes;
        for (0..rounds) |_| {
            const image = try ModuleImage.create(allocator, releases);
            _ = try container.scopeIdForOwned(&image.scope, @ptrCast(image.anchor));
            image.release();
            host.cleanup().drain();
        }
        const stamped_growth = counting.total_requested_bytes -| stamped_base;
        const per_cycle = @sizeOf(RefAnchor) + @sizeOf(env.ScopeCell);
        // Directory pages are installed in blocks, so they are slack above the
        // per-cycle floor rather than part of it. The floor is the assertion
        // that matters: reintroducing in-place header parking would put
        // @sizeOf(ModuleImage) per cycle here instead of an anchor.
        try std.testing.expect(stamped_growth >= rounds * per_cycle);
        try std.testing.expect(stamped_growth <= rounds * per_cycle + 8192);

        container.deinit();
        host.cleanup().reclaimTombstones(destroyParkedAnchor);
        host.cleanup().drain();
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "modules: a borrow holds an image's contents across a full drain" {
    // The necessity half of the borrow's gate, and deliberately deterministic.
    //
    // The stochastic version -- racing a resolver against an image's last
    // release from ECL -- cannot discriminate, because four separate mechanisms
    // already narrow the window to instruction scale that no ECL-level yield can
    // land inside: `unmodule` quiesces the slot before retiring, a live module
    // value legitimately holds its image, the resolution walk's `ShapeLease`
    // together with the environment teardown wait covers the lookup, and
    // `scheduleWord`'s pin covers the frame. So the borrow's necessity is stated
    // here as an API fact instead, where the drop can be constructed exactly and
    // the verdict is the same on every run.
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var host = heap.HostOwner.init(allocator);
        const releases = host.domain();
        var container = try env.Env.init(&host);

        const image = try ModuleImage.create(allocator, releases);
        const owner: *anyopaque = @ptrCast(image.anchor);
        _ = try container.scopeIdForOwned(&image.scope, owner);
        const cell = try container.scopeCell(&image.scope, owner);

        // Through the real primitive, not a hand-rolled retain.
        var borrowed = tryPinAnchorInternal(owner) orelse
            return error.ExpectedLiveBorrow;

        const before_drop = counting.total_requested_bytes;
        // The last reference anything outside the borrow holds.
        image.release();
        host.cleanup().drain();

        // Nothing was reclaimed: the borrow is what holds the contents. Remove
        // the acquire from `executeWord`, or take it after the walk instead of
        // before, and this is the assertion that fails -- on every run.
        //
        // Verified by building the misplaced-pin variant: with the acquire
        // removed the tier does not pass, though it *hangs* rather than failing
        // here, because the later `deinit` releases a count already at zero.
        // Expect a timeout, not a red assertion, if this ever regresses.
        try std.testing.expectEqual(before_drop, counting.total_requested_bytes);
        // And the scope is still reachable through its proof arm, which is what
        // resolution does with it.
        try std.testing.expectEqual(
            @as(?*env.Scope, &image.scope),
            cell.scopeUnder(.fresh_pin),
        );
        try std.testing.expectEqual(
            ModuleHome.init(&image.construction_home),
            homeForModuleRootScope(&image.scope),
        );

        borrowed.deinit();
        host.cleanup().drain();

        // Now the contents are gone, and a borrow attempted after the fact fails
        // its acquire rather than resurrecting anything.
        try std.testing.expect(counting.total_requested_bytes < before_drop);
        try std.testing.expectEqual(
            @as(?GenerationPin, null),
            tryPinAnchorInternal(owner),
        );

        container.deinit();
        host.cleanup().reclaimTombstones(destroyParkedAnchor);
        host.cleanup().drain();
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "modules: the same drop with no borrow reclaims the contents" {
    // The strawman the stochastic tests could not express: identical to the test
    // above except that no borrow is taken. If the contents survived here too,
    // the borrow above would be proving nothing about the borrow.
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var host = heap.HostOwner.init(allocator);
        const releases = host.domain();
        var container = try env.Env.init(&host);

        const image = try ModuleImage.create(allocator, releases);
        const owner: *anyopaque = @ptrCast(image.anchor);
        _ = try container.scopeIdForOwned(&image.scope, owner);

        const before_drop = counting.total_requested_bytes;
        image.release();
        host.cleanup().drain();

        try std.testing.expect(counting.total_requested_bytes < before_drop);
        // The anchor outlived the image, so the failed acquire is a verdict
        // rather than a fault: this read is exactly what a stale word does.
        try std.testing.expectEqual(
            @as(?GenerationPin, null),
            tryPinAnchorInternal(owner),
        );

        container.deinit();
        host.cleanup().reclaimTombstones(destroyParkedAnchor);
        host.cleanup().drain();
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

/// Opaque observation capability owning one registration reference.
pub const GenerationLease = enum(usize) {
    consumed = 0,
    _,

    fn initRetained(retained: *Registration) GenerationLease {
        return @enumFromInt(@intFromPtr(retained));
    }
    fn registration(self: GenerationLease) *Registration {
        std.debug.assert(self != .consumed);
        return @ptrFromInt(@intFromEnum(self));
    }
    pub fn generationNumber(self: GenerationLease) u64 {
        return self.registration().generation;
    }
    pub fn name(self: GenerationLease) intern.ModuleName {
        return self.registration().name;
    }
    pub fn resolveCursor(self: GenerationLease, id: u32) ModuleResolveCursor {
        return self.registration().resolveCursor(id);
    }
    pub fn publicNameCursor(self: GenerationLease) ModulePublicNameCursor {
        return self.registration().publicNameCursor();
    }
    pub fn enterExecution(
        self: *GenerationLease,
        _: *const ExecutionAccess,
    ) ExecutionGeneration {
        const retained = self.registration();
        self.* = .consumed;
        return .initRetained(retained);
    }
    pub fn deinit(self: *GenerationLease) void {
        if (self.* == .consumed) return;
        self.registration().release();
        self.* = .consumed;
    }
};

/// Session-gated execution capability. Observation can be transferred into
/// execution only by code holding the Session-private authority, and the raw
/// registration remains hidden on both sides of the transition. This is the
/// only producer of a registration home, which is why an activation's state
/// and name can only come from the registry lease it was resolved through.
pub const ExecutionGeneration = enum(usize) {
    consumed = 0,
    _,

    fn initRetained(retained: *Registration) ExecutionGeneration {
        return @enumFromInt(@intFromPtr(retained));
    }
    fn registration(self: ExecutionGeneration) *Registration {
        std.debug.assert(self != .consumed);
        return @ptrFromInt(@intFromEnum(self));
    }
    pub fn home(
        self: ExecutionGeneration,
        _: *const ExecutionAccess,
    ) *ModuleHome {
        return .init(&self.registration().home);
    }
    pub fn deinit(self: *ExecutionGeneration) void {
        if (self.* == .consumed) return;
        self.registration().release();
        self.* = .consumed;
    }
};

/// The cursor types an observation lease hands out. Naming them here keeps the
/// registration record itself private to this file.
pub const ModuleResolveCursor = Registration.ResolveCursor;

/// The one export lookup, whether the image was reached through a registered
/// name or as a value. The registry contributes nothing to finding an export;
/// what the home supplies is the pin that keeps the image alive across a
/// resumable cursor, and which privacy and durable-state authority apply.
fn resolveCursorFor(image: *ModuleImage, home: *ModuleHome, id: u32) ModuleResolveCursor {
    return .{
        .allocator = image.allocator,
        .lookup = image.environment.directLookupCursor(id),
        .pin = home.pinInternal(),
    };
}

/// Resolve one public export from an image reached as a *value* rather than
/// through a registered name.
///
/// This is the same lookup a registration performs, because an image's own
/// environment is where its exports live and the registry contributes nothing
/// to finding one. What differs is what is pinned: an image reached this way
/// has no registration, so the `ExecutionHome` a construction body already
/// runs against serves here too, and retaining it retains the image. That is
/// also why such a call has no durable state and no generation — there is no
/// slot to open and no supersession to be current with.
pub fn handleResolveCursor(handle: ImageRef, id: u32) ModuleResolveCursor {
    const image = handle.image();
    return resolveCursorFor(image, ModuleHome.init(&image.construction_home), id);
}

/// The home a value-reached image executes against. Its registration is null,
/// so privacy is by public-only lookup, `within` is refused exactly as it is
/// for a construction root, and the trace spells the bare local name because
/// the image has no canonical one to qualify with.
pub fn handleHome(handle: ImageRef, _: *const ExecutionAccess) *ModuleHome {
    return .init(&handle.image().construction_home);
}
pub const ModulePublicNameCursor = Registration.PublicNameCursor;

/// A borrowed reference to one immutable image, valid for the call it is passed
/// to and no longer. Only a `SealedImage` or a live module value can produce
/// one, so the borrow always starts from something that owns a reference; a
/// consumer that outlives the call — a publication cursor — upgrades it to a
/// `RetainedImage` immediately rather than trusting its caller's lifetime.
pub const ImageRef = enum(usize) {
    _,

    fn init(target: *ModuleImage) ImageRef {
        return @enumFromInt(@intFromPtr(target));
    }
    fn image(self: ImageRef) *ModuleImage {
        return @ptrFromInt(@intFromEnum(self));
    }
};

/// One retained image reference, owned for as long as its holder lives. A
/// publication cursor is resumable across many scheduler turns, so it owns what
/// it dereferences instead of trusting a caller to outlive it: an `ImageRef` is
/// a borrow valid at the call that produced it, and nothing stops the caller
/// from releasing its sealed image before the cursor next advances.
const RetainedImage = enum(usize) {
    consumed = 0,
    _,

    fn retain(borrowed: ImageRef) RetainedImage {
        const target = borrowed.image();
        target.retain();
        return @enumFromInt(@intFromPtr(target));
    }
    fn image(self: RetainedImage) *ModuleImage {
        std.debug.assert(self != .consumed);
        return @ptrFromInt(@intFromEnum(self));
    }
    fn deinit(self: *RetainedImage) void {
        if (self.* == .consumed) return;
        self.image().release();
        self.* = .consumed;
    }
};

/// Unique ownership of an image that no value and no registration holds yet.
/// Every exit either transfers the reference into a module value or releases
/// it; publication never consumes it, because a registration retains its own.
pub const OwnedImage = enum(usize) {
    consumed = 0,
    _,

    fn init(target: *ModuleImage) OwnedImage {
        return @enumFromInt(@intFromPtr(target));
    }
    fn borrow(self: *const OwnedImage) *ModuleImage {
        std.debug.assert(self.* != .consumed);
        return @ptrFromInt(@intFromEnum(self.*));
    }
    pub fn executionHome(
        self: *const OwnedImage,
        _: *const ExecutionAccess,
    ) *ModuleHome {
        return .init(&self.borrow().construction_home);
    }
    pub fn publishDefinition(
        self: *const OwnedImage,
        name: intern.BindingName,
        publication: env.ModulePublication,
    ) env.BindError!*env.BindingCell {
        return self.borrow().environment.modulePublisher().publish(name, publication);
    }
    /// Reserves the construction stack the body left behind. Entries start as
    /// scalars so a partly filled template is always releasable, and the
    /// capture fills them from the top down.
    pub fn reserveTemplate(self: *const OwnedImage, count: usize) error{OutOfMemory}!void {
        const image = self.borrow();
        std.debug.assert(image.initial_state.len == 0);
        if (count == 0) return;
        const buffer = try image.allocator.alloc(value.Value, count);
        @memset(buffer, .{ .int = 0 });
        image.initial_state = buffer;
    }
    /// Moves one construction-stack value into the template. Ownership
    /// transfers to the image, which retires it when the image does; a
    /// registration copies rather than consumes it, so the same template can
    /// seed a second registration.
    pub fn placeTemplate(self: *const OwnedImage, index: usize, item: value.Value) void {
        self.borrow().initial_state[index] = item;
    }
    /// Ends construction. Freezing the environment and consuming this
    /// capability are one transition, so nothing that mutates an image — a
    /// definition, a template slot — remains reachable once the image can be
    /// registered or handed to a program. The environment's frozen flag stops
    /// late definitions; only the typestate stops a late template write, which
    /// has no frozen check because a sealed image has no writer.
    pub fn seal(self: *OwnedImage) SealedImage {
        const image = self.borrow();
        image.environment.modulePublisher().freeze();
        self.* = .consumed;
        return .init(image);
    }
    pub fn move(self: *OwnedImage) OwnedImage {
        const result = self.*;
        std.debug.assert(result != .consumed);
        self.* = .consumed;
        return result;
    }
    pub fn deinit(self: *OwnedImage) void {
        if (self.* == .consumed) return;
        // The construction owner is one lifetime guard, not a uniqueness
        // assertion. Tasks spawned during construction hold independent pins,
        // so rollback drops only this capability and the image remains alive
        // until those tasks and their child scopes quiesce.
        self.borrow().release();
        self.* = .consumed;
    }
};

/// Unique ownership of a finished image. It has no mutation surface at all:
/// the only things left to do with an image are register it, hand it to a
/// program as a value, and release it.
pub const SealedImage = enum(usize) {
    consumed = 0,
    _,

    fn init(target: *ModuleImage) SealedImage {
        return @enumFromInt(@intFromPtr(target));
    }
    fn borrow(self: *const SealedImage) *ModuleImage {
        std.debug.assert(self.* != .consumed);
        return @ptrFromInt(@intFromEnum(self.*));
    }
    /// A borrow for publication. Registration retains its own reference, so
    /// this capability's holder keeps owning the one it was sealed with.
    pub fn ref(self: *const SealedImage) ImageRef {
        return .init(self.borrow());
    }
    pub fn move(self: *SealedImage) SealedImage {
        const result = self.*;
        std.debug.assert(result != .consumed);
        self.* = .consumed;
        return result;
    }
    pub fn deinit(self: *SealedImage) void {
        if (self.* == .consumed) return;
        self.borrow().release();
        self.* = .consumed;
    }
    /// Wraps the image in a value, transferring this capability's reference to
    /// it. On failure nothing is published and the capability is untouched.
    pub fn intoValue(self: *SealedImage, allocator: std.mem.Allocator) error{OutOfMemory}!value.Value {
        const item = try heap.createModule(ModuleImage, allocator, self.borrow());
        self.* = .consumed;
        return item;
    }
};

/// The single conversion between a module value and its image, so no raw cast
/// can be paired at a call site. The reference stays borrowed from the value.
pub fn imageRef(item: value.Value) ?ImageRef {
    if (item != .module) return null;
    const storage = heap.moduleStorage(item.module);
    return .init(@ptrCast(@alignCast(storage.payload)));
}

pub const CommitError = error{
    OutOfMemory,
    NameConflict,
    /// The initiating unit already holds a slot's turn, so it cannot wait
    /// for a second one.
    StateApplicationActive,
};
pub const RemovalError = error{
    OutOfMemory,
    MissingModule,
    StateApplicationActive,
};
pub const AliasError = error{
    OutOfMemory,
    NameConflict,
    MissingModule,
};

/// Identifies who holds a loading lease. A second request from the same
/// owner is a genuine cycle; one from a different owner is ordinary
/// contention, which must wait rather than fail. Storing the owner *as* the
/// lease slot makes the two states one atomic read: there is no window where
/// a node is held by nobody in particular.
pub const LoadingOwner = enum(usize) {
    _,

    pub fn of(holder: *const anyopaque) LoadingOwner {
        return @enumFromInt(@intFromPtr(holder));
    }
    fn token(self: LoadingOwner) usize {
        const raw = @intFromEnum(self);
        std.debug.assert(raw != free_loading_owner);
        return raw;
    }
};
const free_loading_owner: usize = 0;

/// What a request for a loading lease produced.
pub const LoadingOutcome = union(enum) {
    /// The caller owns the load and must release the lease.
    granted: LoadingLease,
    /// This owner already holds a lease on the name.
    cycle,
    /// Another owner holds it; the caller must wait and re-resolve.
    contended,
};

const LoadingNode = struct {
    registry: *Registry,
    name: intern.ModuleName,
    owner: std.atomic.Value(usize),
    next: ?*LoadingNode,
};
pub const LoadingLease = enum(usize) {
    finished = 0,
    _,

    fn init(loading: *LoadingNode) LoadingLease {
        return @enumFromInt(@intFromPtr(loading));
    }
    fn node(self: LoadingLease) *LoadingNode {
        std.debug.assert(self != .finished);
        return @ptrFromInt(@intFromEnum(self));
    }
    pub fn move(self: *LoadingLease) LoadingLease {
        const result = self.*;
        std.debug.assert(result != .finished);
        self.* = .finished;
        return result;
    }
    pub fn finish(self: *LoadingLease) void {
        const loading = self.node();
        loading.owner.store(free_loading_owner, .release);
        self.* = .finished;
    }
    pub fn deinit(self: *LoadingLease) void {
        if (self.* == .finished) return;
        const loading = self.node();
        loading.owner.store(free_loading_owner, .release);
        self.* = .finished;
    }
};
/// Permanent registry inventory node for one slot allocation. The slot owns
/// its nominal `InventoryEntry`; removal moves the slot itself between reuse
/// queues and never scans, detaches, or reallocates this node.
const SlotEntry = struct {
    slot: *ModuleSlot,
    next: ?*SlotEntry = null,
};

const RetiredGeneration = struct {
    generation: *Registration,
    next: ?*RetiredGeneration = null,
};

const RegistryState = struct {
    host: *const heap.HostCleanup,
    writer: std.Io.Mutex = .init,
    directories: DirectoryPublisher,
    inventory: ?*SlotEntry = null,
    slots_pending_head: ?*ModuleSlot = null,
    slots_pending_tail: ?*ModuleSlot = null,
    slots_pending_count: usize = 0,
    slots_ready: ?*ModuleSlot = null,
    retired_head: ?*RetiredGeneration = null,
    retired_tail: ?*RetiredGeneration = null,
    retired_count: usize = 0,
    loading: std.atomic.Value(?*LoadingNode) = .init(null),
};

pub const Registry = enum(usize) {
    consumed = 0,
    _,

    fn privateState(self: *const Registry) *RegistryState {
        std.debug.assert(self.* != .consumed);
        return @ptrFromInt(@intFromEnum(self.*));
    }

    pub fn init(host: *const heap.HostCleanup) error{OutOfMemory}!Registry {
        const owner_allocator = host.allocator();
        const backing = try owner_allocator.create(RegistryState);
        backing.* = .{
            .host = host,
            .directories = .init(null),
        };
        return @enumFromInt(@intFromPtr(backing));
    }

    fn allocator(self: *const Registry) std.mem.Allocator {
        return self.privateState().host.allocator();
    }

    fn releaseDomain(self: *const Registry) *heap.ReleaseDomain {
        return heap.hostDomain(self.privateState().host);
    }

    pub fn deinit(self: *Registry) void {
        const backing = self.privateState();
        const owner_allocator = backing.host.allocator();
        std.debug.assert(backing.directories.quiescent());
        Directory.destroyChain(backing.directories.currentOwned(), self.allocator());
        // First close and detach payloads, but keep slot storage alive while
        // generation retirement releases its SlotLeases.
        var inventory = backing.inventory;
        while (inventory) |entry| : (inventory = entry.next) {
            const owning = entry.slot;
            closeArbiter(owning);
            owning.retire(self.releaseDomain());
        }
        var retired = backing.retired_head;
        while (retired) |entry| {
            const next = entry.next;
            entry.generation.release();
            self.allocator().destroy(entry);
            retired = next;
        }
        var loading = backing.loading.load(.acquire);
        while (loading) |node| {
            loading = node.next;
            self.allocator().destroy(node);
        }
        backing.host.drain();
        inventory = backing.inventory;
        while (inventory) |entry| {
            const next = entry.next;
            const owning = entry.slot;
            std.debug.assert(owning.lease_refs.load(.acquire) == 0);
            self.allocator().destroy(owning);
            self.allocator().destroy(entry);
            inventory = next;
        }
        backing.host.drain();
        owner_allocator.destroy(backing);
        self.* = .consumed;
    }

    fn lockBlocking(self: *Registry) void {
        std.Io.Threaded.mutexLock(&self.privateState().writer);
    }

    fn unlock(self: *Registry) void {
        std.Io.Threaded.mutexUnlock(&self.privateState().writer);
    }

    fn acquireDirectory(self: *const Registry) DirectoryLease {
        const lease = self.privateState().directories.acquire();
        return .{
            .registry = self,
            .directory = lease.snapshot,
            .lease = lease,
        };
    }

    pub const NamespaceProgress = poll.StreamProgress(u32);
    /// Snapshot-owning enumeration of canonical module and alias names. The
    /// directory representation remains private and the lease survives until
    /// the cursor is explicitly released, including when iteration is
    /// abandoned early.
    pub const NamespaceCursor = struct {
        directory: DirectoryLease,
        phase: enum { modules, aliases, complete } = .modules,
        modules: ?Directory.ModuleMap.RawEntryCursor = null,
        aliases: ?Directory.AliasMap.RawEntryCursor = null,

        pub fn deinit(self: *NamespaceCursor) void {
            self.directory.deinit();
            self.* = undefined;
        }

        pub fn advance(self: *NamespaceCursor) NamespaceProgress {
            while (true) switch (self.phase) {
                .modules => {
                    const entries = &(self.modules orelse {
                        self.phase = .aliases;
                        continue;
                    });
                    switch (entries.advance()) {
                        .pending => return .pending,
                        .item => |entry| return .{ .item = intern.moduleId(entry.key) },
                        .complete => {
                            self.modules = null;
                            self.phase = .aliases;
                        },
                    }
                },
                .aliases => {
                    const entries = &(self.aliases orelse {
                        self.phase = .complete;
                        return .complete;
                    });
                    switch (entries.advance()) {
                        .pending => return .pending,
                        .item => |entry| return .{ .item = intern.bindingId(entry.key) },
                        .complete => {
                            self.aliases = null;
                            self.phase = .complete;
                            return .complete;
                        },
                    }
                },
                .complete => return .complete,
            };
        }
    };

    pub fn namespaceCursor(self: *const Registry) NamespaceCursor {
        const directory = self.acquireDirectory();
        return .{
            .directory = directory,
            .modules = if (directory.directory) |current| current.modules.rawEntries() else null,
            .aliases = if (directory.directory) |current| current.aliases.rawEntries() else null,
        };
    }

    fn detachRetiredDirectories(self: *Registry) ?*Directory {
        if (!self.privateState().directories.quiescent()) return null;
        const current = self.privateState().directories.currentOwned() orelse return null;
        const retired = current.previous;
        current.previous = null;
        return retired;
    }

    const MaintenanceProgress = poll.Progress(void);
    /// Bounded registry bookkeeping after the ownership-bearing retirement
    /// has happened. Each step either releases one quiescent generation
    /// record or evaluates one empty slot for reuse.
    const MaintenanceCursor = struct {
        registry: *Registry,
        generation_remaining: usize,
        slot_remaining: usize,
        phase: enum { generations, slots } = .generations,
        fn advance(self: *MaintenanceCursor) MaintenanceProgress {
            return switch (self.phase) {
                .generations => result: {
                    if (self.generation_remaining == 0) {
                        self.phase = .slots;
                        break :result .pending;
                    }
                    self.generation_remaining -= 1;
                    self.registry.lockBlocking();
                    const entry = self.registry.popRetiredGenerationLocked() orelse {
                        self.phase = .slots;
                        self.registry.unlock();
                        break :result .pending;
                    };
                    const generation = entry.generation;
                    const reusable = registrationSlot(generation).?.publisher.quiescent();
                    if (!reusable) self.registry.enqueueRetiredGenerationLocked(entry);
                    self.registry.unlock();
                    if (reusable) {
                        generation.release();
                        self.registry.allocator().destroy(entry);
                    }
                    break :result .pending;
                },
                .slots => result: {
                    if (self.slot_remaining == 0) break :result .complete;
                    self.slot_remaining -= 1;
                    self.registry.lockBlocking();
                    const slot = self.registry.popPendingSlotLocked() orelse {
                        self.slot_remaining = 0;
                        self.registry.unlock();
                        break :result .complete;
                    };
                    if (self.registry.slotReusableLocked(slot))
                        self.registry.pushReadySlotLocked(slot)
                    else
                        self.registry.enqueuePendingSlotLocked(slot);
                    self.registry.unlock();
                    break :result .pending;
                },
            };
        }
    };
    fn maintenanceCursor(self: *Registry) MaintenanceCursor {
        self.lockBlocking();
        defer self.unlock();
        return .{
            .registry = self,
            .generation_remaining = self.privateState().retired_count,
            .slot_remaining = self.privateState().slots_pending_count,
        };
    }

    fn enqueueRetiredGenerationLocked(self: *Registry, entry: *RetiredGeneration) void {
        const backing = self.privateState();
        std.debug.assert(entry.next == null);
        if (backing.retired_tail) |tail|
            tail.next = entry
        else
            backing.retired_head = entry;
        backing.retired_tail = entry;
        backing.retired_count += 1;
    }

    fn popRetiredGenerationLocked(self: *Registry) ?*RetiredGeneration {
        const backing = self.privateState();
        const entry = backing.retired_head orelse return null;
        backing.retired_head = entry.next;
        if (backing.retired_head == null) backing.retired_tail = null;
        backing.retired_count -= 1;
        entry.next = null;
        return entry;
    }

    /// Pop one already-proven reusable slot. Potentially blocked slots are
    /// serviced one at a time by `MaintenanceCursor`; publication never scans the
    /// pending history while holding the writer lock.
    fn takeRecycledSlot(self: *Registry) ?*ModuleSlot {
        self.lockBlocking();
        defer self.unlock();
        const backing = self.privateState();
        const ready = backing.slots_ready orelse return null;
        backing.slots_ready = ready.next_recycled;
        ready.next_recycled = null;
        std.debug.assert(self.slotReusableLocked(ready));
        return ready;
    }

    fn slotReusableLocked(self: *Registry, slot: *ModuleSlot) bool {
        const backing = self.privateState();
        if (backing.directories.currentOwned()) |current| {
            if (current.previous != null) return false;
        }
        return slot.phase.load(.acquire) == .retired and
            arbiterQuiescent(slot) and slot.lease_refs.load(.acquire) == 0;
    }

    fn enqueuePendingSlotLocked(self: *Registry, slot: *ModuleSlot) void {
        const backing = self.privateState();
        std.debug.assert(slot.next_recycled == null);
        if (backing.slots_pending_tail) |tail|
            tail.next_recycled = slot
        else
            backing.slots_pending_head = slot;
        backing.slots_pending_tail = slot;
        backing.slots_pending_count += 1;
    }

    fn popPendingSlotLocked(self: *Registry) ?*ModuleSlot {
        const backing = self.privateState();
        const slot = backing.slots_pending_head orelse return null;
        backing.slots_pending_head = slot.next_recycled;
        if (backing.slots_pending_head == null) backing.slots_pending_tail = null;
        backing.slots_pending_count -= 1;
        slot.next_recycled = null;
        return slot;
    }

    fn pushReadySlotLocked(self: *Registry, slot: *ModuleSlot) void {
        std.debug.assert(slot.next_recycled == null);
        slot.next_recycled = self.privateState().slots_ready;
        self.privateState().slots_ready = slot;
    }

    fn recycleSlot(self: *Registry, owning: *ModuleSlot) void {
        self.lockBlocking();
        defer self.unlock();
        self.enqueuePendingSlotLocked(owning);
    }

    fn recordFreshSlotLocked(self: *Registry, owning: *ModuleSlot) void {
        const entry = owning.inventory.node();
        std.debug.assert(entry.slot == owning and entry.next == null);
        entry.next = self.privateState().inventory;
        self.privateState().inventory = entry;
    }

    /// A fresh anonymous image. Naming it is a separate, later decision, so
    /// nothing here validates or reserves a registry name.
    pub fn createImage(self: *Registry) error{OutOfMemory}!OwnedImage {
        return .init(try ModuleImage.create(self.allocator(), self.releaseDomain()));
    }

    pub const NativeCandidateProgress = poll.Progress(OwnedImage);

    /// The single bounded native-definition publication path used by dynamic
    /// loading and static transport verification. Each turn installs at most
    /// one validated definition into the unpublished generation.
    pub const NativeCandidateCursor = struct {
        instance: *native_module.ModuleInstance,
        candidate: ?OwnedImage,
        definition_index: usize = 0,

        pub fn init(
            registry: *Registry,
            instance: *native_module.ModuleInstance,
        ) error{OutOfMemory}!NativeCandidateCursor {
            return .{
                .instance = instance,
                .candidate = try registry.createImage(),
            };
        }

        pub fn deinit(self: *NativeCandidateCursor) void {
            if (self.candidate) |*candidate| candidate.deinit();
            self.* = undefined;
        }

        pub fn advance(self: *NativeCandidateCursor) error{OutOfMemory}!NativeCandidateProgress {
            const definitions = self.instance.validated().definitions();
            if (self.definition_index == definitions.len) {
                const completed = self.candidate.?.move();
                self.candidate = null;
                return .{ .complete = completed };
            }
            const definition = definitions[self.definition_index];
            _ = self.candidate.?.publishDefinition(definition.name, .{ .native = .{
                .callable = .{
                    .instance = self.instance,
                    .definition = @intCast(self.definition_index),
                },
                .visibility = .public,
                .effect = definition.effect,
                .doc = definition.doc,
            } }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Frozen => unreachable,
            };
            self.definition_index += 1;
            return .pending;
        }
    };

    pub const BuiltinCandidateProgress = poll.Progress(OwnedImage);

    /// Publication path for builtin-backed modules. One turn installs one
    /// word, so a module with many words is as bounded as a native one; the
    /// effect and documentation values are built from the compiled-in text
    /// whose size is fixed at compile time.
    pub const BuiltinCandidateCursor = struct {
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        words: []const env.BuiltinWord,
        candidate: ?OwnedImage,
        word_index: usize = 0,

        pub fn init(
            registry: *Registry,
            words: []const env.BuiltinWord,
        ) error{OutOfMemory}!BuiltinCandidateCursor {
            return .{
                .allocator = registry.allocator(),
                .releases = registry.releaseDomain(),
                .words = words,
                .candidate = try registry.createImage(),
            };
        }

        pub fn deinit(self: *BuiltinCandidateCursor) void {
            if (self.candidate) |*candidate| candidate.deinit();
            self.* = undefined;
        }

        pub const Error = error{ OutOfMemory, InvalidName };

        pub fn advance(self: *BuiltinCandidateCursor) Error!BuiltinCandidateProgress {
            if (self.word_index == self.words.len) {
                const completed = self.candidate.?.move();
                self.candidate = null;
                return .{ .complete = completed };
            }
            const word = self.words[self.word_index];
            // Publication retains what it is handed, so this cursor releases
            // its own reference on every path.
            const document = try self.buildDocumentation(word.doc);
            defer self.releases.releaseHeader(env.documentationHeader(document));
            const effect = if (word.effect) |source| try self.buildEffect(source) else null;
            defer if (effect) |built| built.retire(self.releases);
            _ = self.candidate.?.publishDefinition(
                try intern.internNamespace(word.name),
                .{ .builtin = .{
                    .primitive = word.primitive,
                    .visibility = .public,
                    .effect = effect,
                    .doc = document,
                } },
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // The manifest validates names and holds no duplicates at
                // compile time, and a fresh candidate is never frozen.
                error.Frozen => return error.InvalidName,
            };
            self.word_index += 1;
            return .pending;
        }

        /// Compiled-in documentation is authored already normalized, so the
        /// text becomes a string value directly.
        fn buildDocumentation(
            self: *BuiltinCandidateCursor,
            source: []const u8,
        ) error{OutOfMemory}!*env.DocumentationString {
            var materializer = kernel_storage.TextMaterializer.init(self.allocator, source);
            defer materializer.retire(self.releases);
            const text = try poll_api.driveFallible(value.Value, &materializer, .{64});
            return env.documentation(text.list) orelse {
                self.releases.releaseValue(text);
                return error.OutOfMemory;
            };
        }

        fn buildEffect(
            self: *BuiltinCandidateCursor,
            source: []const u8,
        ) error{OutOfMemory}!env.ValidatedEffect {
            var tokens: [env.max_builtin_effect_tokens]value.Value = undefined;
            var count: usize = 0;
            var iterator = std.mem.tokenizeAny(u8, source, " \t");
            while (iterator.next()) |token| {
                if (count == tokens.len) return error.OutOfMemory;
                tokens[count] = .{ .word = .{ .name = try intern.intern(token) } };
                count += 1;
            }
            const owned = try list.fromValuesGeneric(self.allocator, tokens[0..count]);
            return env.ValidatedEffect.parse(owned.list, try intern.intern("--")) orelse {
                self.releases.releaseValue(owned);
                return error.OutOfMemory;
            };
        }
    };

    pub const CommitProgress = poll.Progress(u64);
    /// Publishes one image under one canonical name. Registration is an
    /// upsert: a missing name creates a slot and seeds its durable stack from
    /// a *copy* of the image's template, while an existing name installs the
    /// new image and keeps the state that slot already owns.
    ///
    /// The cursor retains the image for its whole lifetime and releases it on
    /// every exit; the registration it publishes retains an independent
    /// reference. Every abandoned path leaves the caller's reference, the prior
    /// directory, the prior generation, and the slot's durable stack exactly as
    /// they were.
    pub const RegistrationCursor = struct {
        const ModuleBuilder = union(enum) {
            initialize: Directory.ModuleMap.InitCursor,
            clone: Directory.ModuleMap.CloneCursor,

            fn deinit(self: *ModuleBuilder) void {
                switch (self.*) {
                    inline else => |*cursor| cursor.deinit(),
                }
            }
        };
        const AliasBuilder = union(enum) {
            initialize: Directory.AliasMap.InitCursor,
            clone: Directory.AliasMap.CloneCursor,

            fn deinit(self: *AliasBuilder) void {
                switch (self.*) {
                    inline else => |*cursor| cursor.deinit(),
                }
            }
        };
        const Snapshot = struct {
            directory: DirectoryLease,
            old: ?*const Directory,
        };
        const NewBuild = struct {
            snapshot: Snapshot,
            modules: Directory.ModuleMap,
            aliases: Directory.AliasMap,
            slot: union(enum) {
                fresh: *ModuleSlot,
                recycled: *ModuleSlot,

                fn get(self: @This()) *ModuleSlot {
                    return switch (self) {
                        inline else => |slot| slot,
                    };
                }
            },
            /// The new slot's durable stack, copied from the image template.
            /// Entries are scalars until the copy fills them, so an abandoned
            /// build is always releasable.
            state: []value.Value = &.{},
            copied: usize = 0,
        };
        const State = union(enum) {
            maintenance: MaintenanceCursor,
            snapshot,
            alias: struct {
                snapshot: Snapshot,
                cursor: Directory.AliasMap.RawLookupCursor,
            },
            module: struct {
                snapshot: Snapshot,
                cursor: ?Directory.ModuleMap.RawLookupCursor,
            },
            modules: struct {
                snapshot: Snapshot,
                builder: ModuleBuilder,
            },
            aliases: struct {
                snapshot: Snapshot,
                modules: Directory.ModuleMap,
                builder: AliasBuilder,
            },
            prepare_insert: struct {
                snapshot: Snapshot,
                modules: Directory.ModuleMap,
                aliases: Directory.AliasMap,
            },
            insert: struct {
                build: *NewBuild,
                cursor: Directory.ModuleMap.PutCursor,
            },
            seed_state: *NewBuild,
            barrier: struct {
                lease: SlotLease,
                requested: bool = false,
            },
            commit_existing,
            commit_new: *NewBuild,
            complete,
        };

        registry: *Registry,
        /// Retained for the cursor's whole lifetime and released by `deinit`,
        /// so the template stays readable across every resumption regardless of
        /// what the caller does with its own reference.
        image: RetainedImage,
        name: intern.ModuleName,
        authority: *TurnAuthority,
        state: State,
        /// The generation record for this publication. It retains the image on
        /// creation, so an abandoned cursor releases it rather than leaking a
        /// reference the caller never granted.
        registration: ?*Registration = null,
        /// The barrier turn, held outside the state union so publication can
        /// release it after the state has advanced to `.complete`. Its
        /// address is what the arbiter links, and the cursor never moves
        /// once a turn is requested.
        barrier_turn: ?StateTurn = null,
        /// Reload reserves its retirement record before entering the writer
        /// lock; publication only links this already-owned node.
        retired_reservation: ?*RetiredGeneration = null,

        pub fn init(
            registry: *Registry,
            image: ImageRef,
            name: intern.ModuleName,
            authority: *TurnAuthority,
        ) RegistrationCursor {
            return .{
                .registry = registry,
                .image = .retain(image),
                .name = name,
                .authority = authority,
                .state = .{ .maintenance = registry.maintenanceCursor() },
            };
        }
        pub fn deinit(self: *RegistrationCursor) void {
            self.image.deinit();
            if (self.barrier_turn) |*turn| turn.release();
            if (self.retired_reservation) |record| self.registry.allocator().destroy(record);
            if (self.registration) |registration| registration.release();
            switch (self.state) {
                .alias => |*state| state.snapshot.directory.deinit(),
                .module => |*state| state.snapshot.directory.deinit(),
                .modules => |*state| {
                    state.builder.deinit();
                    state.snapshot.directory.deinit();
                },
                .aliases => |*state| {
                    state.builder.deinit();
                    state.modules.deinit();
                    state.snapshot.directory.deinit();
                },
                .prepare_insert => |*state| {
                    state.modules.deinit();
                    state.aliases.deinit();
                    state.snapshot.directory.deinit();
                },
                .insert => |state| self.destroyBuild(state.build),
                .seed_state => |build| self.destroyBuild(build),
                .commit_new => |build| self.destroyBuild(build),
                .barrier => |*state| if (!state.requested) state.lease.deinit(),
                .maintenance, .snapshot, .commit_existing, .complete => {},
            }
            self.* = undefined;
        }
        fn destroyBuild(self: *RegistrationCursor, build: *NewBuild) void {
            build.modules.deinit();
            build.aliases.deinit();
            for (build.state) |item| self.registry.releaseDomain().releaseValue(item);
            if (build.state.len != 0) self.registry.allocator().free(build.state);
            switch (build.slot) {
                .fresh => |slot| {
                    // Never published, so the slot owns nothing beyond its own
                    // storage and its inventory node.
                    self.registry.allocator().destroy(slot.inventory.node());
                    self.registry.allocator().destroy(slot);
                },
                .recycled => |slot| self.registry.recycleSlot(slot),
            }
            build.snapshot.directory.deinit();
            self.registry.allocator().destroy(build);
        }
        /// The one place a generation record is created, so both publication
        /// paths retain the image identically and neither can forget to.
        fn prepareRegistration(self: *RegistrationCursor) error{OutOfMemory}!void {
            if (self.registration != null) return;
            self.registration = try Registration.create(
                self.registry.allocator(),
                self.image.image(),
                self.name,
            );
        }
        fn takeRegistration(self: *RegistrationCursor) *Registration {
            const registration = self.registration.?;
            self.registration = null;
            return registration;
        }
        pub fn advance(self: *RegistrationCursor) CommitError!CommitProgress {
            const name = self.name;
            return switch (self.state) {
                .maintenance => |*maintenance| switch (maintenance.advance()) {
                    .pending => .pending,
                    .complete => result: {
                        self.state = .snapshot;
                        break :result .pending;
                    },
                },
                .snapshot => result: {
                    const directory = self.registry.acquireDirectory();
                    const snapshot = Snapshot{
                        .old = directory.directory,
                        .directory = directory,
                    };
                    if (snapshot.old) |old| {
                        if (intern.moduleBindingName(name)) |alias_name| {
                            self.state = .{ .alias = .{
                                .snapshot = snapshot,
                                .cursor = old.aliases.rawLookup(alias_name),
                            } };
                        } else {
                            self.state = .{ .module = .{
                                .snapshot = snapshot,
                                .cursor = old.modules.rawLookup(name),
                            } };
                        }
                    } else {
                        self.state = .{ .module = .{
                            .snapshot = snapshot,
                            .cursor = null,
                        } };
                    }
                    break :result .pending;
                },
                .alias => |*state| switch (state.cursor.advance()) {
                    .pending => .pending,
                    .complete => |existing_alias| result: {
                        if (existing_alias != null) return error.NameConflict;
                        self.state = .{ .module = .{
                            .snapshot = state.snapshot,
                            .cursor = state.snapshot.old.?.modules.rawLookup(name),
                        } };
                        break :result .pending;
                    },
                },
                .module => |*state| if (state.cursor) |*lookup| switch (lookup.advance()) {
                    .pending => .pending,
                    .complete => |maybe_slot| result: {
                        if (maybe_slot) |slot| {
                            const lease = SlotLease.retain(slot);
                            state.snapshot.directory.deinit();
                            self.state = .{ .barrier = .{ .lease = lease } };
                        } else {
                            self.state = .{ .modules = .{
                                .snapshot = state.snapshot,
                                .builder = .{ .clone = state.snapshot.old.?.modules.cloneCursor(1) },
                            } };
                        }
                        break :result .pending;
                    },
                } else result: {
                    self.state = .{ .modules = .{
                        .snapshot = state.snapshot,
                        .builder = .{ .initialize = Directory.ModuleMap.initCursor(
                            self.registry.allocator(),
                            1,
                        ) },
                    } };
                    break :result .pending;
                },
                .modules => |*state| switch (state.builder) {
                    inline else => |*builder| switch (try builder.advance()) {
                        .pending => .pending,
                        .complete => |modules| result: {
                            builder.deinit();
                            const alias_builder: AliasBuilder = if (state.snapshot.old) |old|
                                .{ .clone = old.aliases.cloneCursor(0) }
                            else
                                .{ .initialize = Directory.AliasMap.initCursor(
                                    self.registry.allocator(),
                                    0,
                                ) };
                            self.state = .{ .aliases = .{
                                .snapshot = state.snapshot,
                                .modules = modules,
                                .builder = alias_builder,
                            } };
                            break :result .pending;
                        },
                    },
                },
                .aliases => |*state| switch (state.builder) {
                    inline else => |*builder| switch (try builder.advance()) {
                        .pending => .pending,
                        .complete => |aliases| result: {
                            builder.deinit();
                            self.state = .{ .prepare_insert = .{
                                .snapshot = state.snapshot,
                                .modules = state.modules,
                                .aliases = aliases,
                            } };
                            break :result .pending;
                        },
                    },
                },
                .prepare_insert => |*state| result: {
                    const build = try self.registry.allocator().create(NewBuild);
                    errdefer self.registry.allocator().destroy(build);
                    const prepared_slot = try self.registry.allocator().create(ModuleSlot);
                    errdefer self.registry.allocator().destroy(prepared_slot);
                    const prepared_entry = try self.registry.allocator().create(SlotEntry);
                    errdefer self.registry.allocator().destroy(prepared_entry);
                    prepared_entry.* = .{ .slot = prepared_slot };
                    prepared_slot.* = .{
                        .inventory = .init(prepared_entry),
                        .allocator = self.registry.allocator(),
                    };
                    const slot_source: @TypeOf(build.slot) = if (self.registry.takeRecycledSlot()) |recycled| source: {
                        self.registry.allocator().destroy(prepared_entry);
                        self.registry.allocator().destroy(prepared_slot);
                        break :source .{ .recycled = recycled };
                    } else .{ .fresh = prepared_slot };
                    const slot = slot_source.get();
                    build.* = .{
                        .snapshot = state.snapshot,
                        .modules = state.modules,
                        .aliases = state.aliases,
                        .slot = slot_source,
                    };
                    self.state = .{ .insert = .{
                        .build = build,
                        .cursor = build.modules.putCursor(name, slot),
                    } };
                    break :result .pending;
                },
                .insert => |*state| switch (state.cursor.advance()) {
                    .pending => .pending,
                    .complete => result: {
                        const template = self.image.image().initial_state;
                        if (template.len != 0)
                            state.build.state = try self.registry.allocator().alloc(
                                value.Value,
                                template.len,
                            );
                        @memset(state.build.state, .{ .int = 0 });
                        self.state = .{ .seed_state = state.build };
                        break :result .pending;
                    },
                },
                // A first registration *copies* the template rather than
                // consuming it: the same image may seed another slot later, so
                // the template stays the image's own immutable property.
                .seed_state => |build| result: {
                    const template = self.image.image().initial_state;
                    if (build.copied != template.len) {
                        const item = template[build.copied];
                        heap.retainValue(item);
                        build.state[build.copied] = item;
                        build.copied += 1;
                        break :result .pending;
                    }
                    try self.prepareRegistration();
                    self.state = .{ .commit_new = build };
                    break :result .pending;
                },
                // Re-registration takes an ordinary place in the slot's fair
                // FIFO. Every application queued before it therefore runs
                // against the old generation and finishes first, and every
                // later one queues behind the publication, so no application
                // ever straddles the swap. An idle slot grants the turn on
                // request, which keeps the sequential reload immediate.
                .barrier => |*state| result: {
                    if (!state.requested) {
                        state.requested = true;
                        self.barrier_turn = .init(state.lease.move(), self.authority);
                        self.barrier_turn.?.request() catch |err| switch (err) {
                            // A unit inside a state application already holds
                            // one slot; waiting for a second is the deadlock
                            // shape `within` refuses everywhere else.
                            error.StateApplicationActive => {
                                self.barrier_turn.?.release();
                                self.barrier_turn = null;
                                return error.StateApplicationActive;
                            },
                            // The slot closed while this cursor was
                            // resolving: start over, so the name is looked up
                            // again in the directory the close published.
                            error.ModuleRemoved => {
                                self.barrier_turn.?.release();
                                self.barrier_turn = null;
                                self.state = .snapshot;
                                break :result .pending;
                            },
                        };
                    }
                    if (!self.barrier_turn.?.granted()) break :result .pending;
                    if (self.retired_reservation == null)
                        self.retired_reservation = try self.registry.allocator().create(RetiredGeneration);
                    // Removal may have won the turn ahead of this cursor, so
                    // the slot is re-validated after the grant rather than
                    // only at lookup. Nothing has been published yet, so the
                    // retry still owns everything it arrived with.
                    const slot = self.barrier_turn.?.lease.slot();
                    if (slot.phase.load(.acquire) != .live) {
                        self.registry.allocator().destroy(self.retired_reservation.?);
                        self.retired_reservation = null;
                        self.barrier_turn.?.release();
                        self.barrier_turn = null;
                        self.state = .snapshot;
                        break :result .pending;
                    }
                    try self.prepareRegistration();
                    self.state = .commit_existing;
                    break :result .pending;
                },
                // Replacement installs new code over live state: the slot
                // keeps the durable stack it already owns and this image's
                // template is simply not consulted for that slot.
                .commit_existing => result: {
                    const slot = self.barrier_turn.?.lease.slot();
                    const retired = self.retired_reservation.?;
                    const registration = self.registration.?;
                    self.registry.lockBlocking();
                    const prior = slot.publisher.currentOwned().?;
                    std.debug.assert(slot.phase.load(.acquire) == .live);
                    retired.* = .{ .generation = prior };
                    registration.generation = prior.generation + 1;
                    registration.slot_lifetime = .{ .published = SlotLease.retain(slot) };
                    slot.publisher.publish(self.takeRegistration());
                    const release_prior = slot.publisher.quiescent();
                    if (!release_prior) self.registry.enqueueRetiredGenerationLocked(retired);
                    self.registry.unlock();
                    self.retired_reservation = null;
                    if (release_prior) {
                        prior.release();
                        self.registry.allocator().destroy(retired);
                    }
                    if (self.barrier_turn) |*turn| turn.release();
                    self.state = .complete;
                    break :result .{ .complete = registration.generation };
                },
                .commit_new => |build| result: {
                    const slot = build.slot.get();
                    const next = try self.registry.allocator().create(Directory);
                    self.registry.lockBlocking();
                    if (!self.registry.privateState().directories.isCurrent(build.snapshot.old)) {
                        self.registry.unlock();
                        self.registry.allocator().destroy(next);
                        self.destroyBuild(build);
                        self.state = .snapshot;
                        break :result .pending;
                    }
                    switch (build.slot) {
                        .fresh => self.registry.recordFreshSlotLocked(slot),
                        .recycled => slot.resetForReuse(),
                    }
                    next.* = .{
                        .modules = build.modules,
                        .aliases = build.aliases,
                        .previous = @constCast(build.snapshot.old),
                    };
                    const registration = self.registration.?;
                    registration.generation = 1;
                    registration.slot_lifetime = .{ .published = SlotLease.retain(slot) };
                    slot.state = build.state;
                    build.state = &.{};
                    slot.publisher.publish(self.takeRegistration());
                    self.registry.privateState().directories.publish(next);
                    self.registry.unlock();
                    build.snapshot.directory.deinit();
                    self.registry.allocator().destroy(build);
                    self.state = .complete;
                    break :result .{ .complete = 1 };
                },
                .complete => unreachable,
            };
        }
    };

    pub fn registrationCursor(
        self: *Registry,
        image: ImageRef,
        name: intern.ModuleName,
        authority: *TurnAuthority,
    ) RegistrationCursor {
        return .init(self, image, name, authority);
    }

    /// Cancellation-independent owner of all work after the directory close
    /// edge. The initiating Unit transfers its granted turn and detached
    /// durable stack here before it can observe cancellation again.
    const RemovalRetirement = struct {
        registry: *Registry,
        turn: StateTurn,
        state: []value.Value = &.{},
        remaining: usize = 0,
        retirement: heap.ReleaseDomain.Retirement = .{},

        fn abort(self: *RemovalRetirement) void {
            std.debug.assert(self.state.len == 0);
            self.turn.release();
            self.registry.allocator().destroy(self);
        }

        pub fn advanceRetirement(
            releases: *heap.ReleaseDomain,
            owner_allocator: std.mem.Allocator,
            self: *RemovalRetirement,
        ) bool {
            if (self.remaining != 0) {
                self.remaining -= 1;
                const stale = self.state[self.remaining];
                self.state[self.remaining] = .{ .int = 0 };
                releases.releaseValue(stale);
                return false;
            }
            if (self.state.len != 0) owner_allocator.free(self.state);
            self.state = &.{};
            const owning = self.turn.lease.slot();
            owning.retireEmpty();
            self.registry.recycleSlot(owning);
            self.turn.release();
            owner_allocator.destroy(self);
            return true;
        }
    };

    pub const RemovalProgress = enum { pending, detached, complete };
    /// The owner-issued removal protocol: close new resolution, take the
    /// slot's barrier turn so no state application straddles the close, then
    /// retire the code generation and every durable value through bounded
    /// work. Session shutdown consumes the same transitions.
    pub const RemovalCursor = struct {
        registry: *Registry,
        requested: intern.ModuleName,
        authority: *TurnAuthority,
        state: State = .snapshot,

        const State = union(enum) {
            snapshot,
            alias: struct {
                directory: DirectoryLease,
                lookup: Directory.AliasMap.RawLookupCursor,
            },
            module: struct {
                canonical: intern.ModuleName,
                directory: DirectoryLease,
                lookup: Directory.ModuleMap.RawLookupCursor,
            },
            barrier: struct {
                canonical: intern.ModuleName,
                directory: DirectoryLease,
                retirement: *RemovalRetirement,
            },
            modules_map: struct {
                canonical: intern.ModuleName,
                directory: DirectoryLease,
                retirement: *RemovalRetirement,
                cloner: Directory.ModuleMap.CloneExcludingCursor,
            },
            aliases_map: struct {
                canonical: intern.ModuleName,
                directory: DirectoryLease,
                retirement: *RemovalRetirement,
                modules: Directory.ModuleMap,
                cloner: Directory.AliasMap.CloneExcludingCursor,
            },
            commit: struct {
                canonical: intern.ModuleName,
                directory: DirectoryLease,
                retirement: *RemovalRetirement,
                modules: Directory.ModuleMap,
                aliases: Directory.AliasMap,
            },
            /// Observation-only witness used to report ordinary completion
            /// after detached retirement reaches `.retired`. Cancellation may
            /// drop it; it owns none of the cleanup work.
            transferred: SlotLease,
            settle_reuse: MaintenanceCursor,
            failed: DirectoryLease,
            complete,
        };

        pub fn deinit(self: *RemovalCursor) void {
            switch (self.state) {
                .snapshot, .settle_reuse, .complete => {},
                .alias => |*state| state.directory.deinit(),
                .module => |*state| state.directory.deinit(),
                .barrier => |*state| {
                    state.retirement.abort();
                    state.directory.deinit();
                },
                .modules_map => |*state| {
                    state.cloner.deinit();
                    state.retirement.abort();
                    state.directory.deinit();
                },
                .aliases_map => |*state| {
                    state.cloner.deinit();
                    state.modules.deinit();
                    state.retirement.abort();
                    state.directory.deinit();
                },
                .commit => |*state| {
                    state.modules.deinit();
                    state.aliases.deinit();
                    state.retirement.abort();
                    state.directory.deinit();
                },
                .transferred => |*completion| completion.deinit(),
                .failed => |*directory| directory.deinit(),
            }
            self.* = undefined;
        }

        pub fn advance(self: *RemovalCursor) RemovalError!RemovalProgress {
            return switch (self.state) {
                .snapshot => result: {
                    var directory = self.registry.acquireDirectory();
                    const old = directory.directory orelse {
                        directory.deinit();
                        return error.MissingModule;
                    };
                    if (intern.moduleBindingName(self.requested)) |alias_name| {
                        self.state = .{ .alias = .{
                            .directory = directory,
                            .lookup = old.aliases.rawLookup(alias_name),
                        } };
                    } else {
                        self.state = .{ .module = .{
                            .canonical = self.requested,
                            .directory = directory,
                            .lookup = old.modules.rawLookup(self.requested),
                        } };
                    }
                    break :result .pending;
                },
                // Every name that can reach a module can also remove it, so a
                // A short alias canonicalizes through the registry directory.
                .alias => |*alias_state| switch (alias_state.lookup.advance()) {
                    .pending => .pending,
                    .complete => |canonical_name| result: {
                        const canonical = canonical_name orelse self.requested;
                        const directory = alias_state.directory;
                        self.state = .{ .module = .{
                            .canonical = canonical,
                            .directory = directory,
                            .lookup = directory.directory.?.modules.rawLookup(canonical),
                        } };
                        break :result .pending;
                    },
                },
                .module => |*module| switch (module.lookup.advance()) {
                    .pending => .pending,
                    .complete => |maybe_slot| result: {
                        const found = maybe_slot orelse return error.MissingModule;
                        const retirement = try self.registry.allocator().create(RemovalRetirement);
                        retirement.* = .{
                            .registry = self.registry,
                            .turn = .init(SlotLease.retain(found), self.authority),
                        };
                        self.state = .{ .barrier = .{
                            .canonical = module.canonical,
                            .directory = module.directory,
                            .retirement = retirement,
                        } };
                        break :result .pending;
                    },
                },
                .barrier => |*barrier| result: {
                    const retirement = barrier.retirement;
                    if (!retirement.turn.linked) {
                        retirement.turn.request() catch |err| switch (err) {
                            error.StateApplicationActive => {
                                const directory = barrier.directory;
                                self.state = .{ .failed = directory };
                                retirement.abort();
                                return error.StateApplicationActive;
                            },
                            // Another removal of the same name won the race.
                            error.ModuleRemoved => {
                                const directory = barrier.directory;
                                self.state = .{ .failed = directory };
                                retirement.abort();
                                return error.MissingModule;
                            },
                        };
                        break :result .pending;
                    }
                    if (!retirement.turn.granted()) break :result .pending;
                    self.state = .{ .modules_map = .{
                        .canonical = barrier.canonical,
                        .directory = barrier.directory,
                        .retirement = retirement,
                        .cloner = barrier.directory.directory.?.modules
                            .cloneExcludingCursor(barrier.canonical, null),
                    } };
                    break :result .pending;
                },
                .modules_map => |*modules_state| switch (try modules_state.cloner.advance()) {
                    .pending => .pending,
                    .complete => |map| result: {
                        modules_state.cloner.deinit();
                        self.state = .{ .aliases_map = .{
                            .canonical = modules_state.canonical,
                            .directory = modules_state.directory,
                            .retirement = modules_state.retirement,
                            .modules = map,
                            .cloner = modules_state.directory.directory.?.aliases
                                .cloneExcludingCursor(null, modules_state.canonical),
                        } };
                        break :result .pending;
                    },
                },
                .aliases_map => |*aliases_state| switch (try aliases_state.cloner.advance()) {
                    .pending => .pending,
                    .complete => |map| result: {
                        aliases_state.cloner.deinit();
                        self.state = .{ .commit = .{
                            .canonical = aliases_state.canonical,
                            .directory = aliases_state.directory,
                            .retirement = aliases_state.retirement,
                            .modules = aliases_state.modules,
                            .aliases = map,
                        } };
                        break :result .pending;
                    },
                },
                // One publish is the close edge: concurrent resolution sees
                // either the live module or nothing, never a half-removed
                // entry, and every alias targeting the slot goes with it.
                .commit => |*commit| result: {
                    const next = try self.registry.allocator().create(Directory);
                    self.registry.lockBlocking();
                    if (!self.registry.privateState().directories.isCurrent(commit.directory.directory)) {
                        self.registry.unlock();
                        self.registry.allocator().destroy(next);
                        var directory = commit.directory;
                        var modules = commit.modules;
                        var aliases = commit.aliases;
                        const retirement = commit.retirement;
                        self.state = .snapshot;
                        modules.deinit();
                        aliases.deinit();
                        retirement.abort();
                        directory.deinit();
                        break :result .pending;
                    }
                    next.* = .{
                        .modules = commit.modules,
                        .aliases = commit.aliases,
                        .previous = @constCast(commit.directory.directory),
                    };
                    const retirement = commit.retirement;
                    const owning = retirement.turn.lease.slot();
                    closeArbiter(owning);
                    retirement.state = owning.state;
                    retirement.remaining = owning.state.len;
                    owning.state = &.{};
                    retirement.turn.detachUnitAuthority();
                    const completion = retirement.turn.lease.clone();
                    self.registry.privateState().directories.publish(next);
                    self.registry.unlock();
                    commit.directory.deinit();
                    self.state = .{ .transferred = completion };
                    self.registry.releaseDomain().retire(retirement, &retirement.retirement);
                    break :result .detached;
                },
                .transferred => |*completion| result: {
                    if (completion.slot().phase.load(.acquire) != .retired)
                        break :result .pending;
                    completion.deinit();
                    self.state = .{ .settle_reuse = self.registry.maintenanceCursor() };
                    break :result .detached;
                },
                .settle_reuse => |*maintenance| switch (maintenance.advance()) {
                    .pending => .pending,
                    .complete => result: {
                        self.state = .complete;
                        break :result .complete;
                    },
                },
                .failed, .complete => unreachable,
            };
        }
    };
    pub fn removalCursor(
        self: *Registry,
        requested: intern.ModuleName,
        authority: *TurnAuthority,
    ) RemovalCursor {
        return .{
            .registry = self,
            .requested = requested,
            .authority = authority,
        };
    }

    pub const AliasProgress = poll.Progress(void);
    pub const AliasCursor = struct {
        registry: *Registry,
        short: intern.BindingName,
        target: intern.ModuleName,
        state: State = .snapshot,

        const State = union(enum) {
            snapshot,
            short_module: struct {
                directory: DirectoryLease,
                lookup: Directory.ModuleMap.RawLookupCursor,
            },
            target_module: struct {
                directory: DirectoryLease,
                lookup: Directory.ModuleMap.RawLookupCursor,
            },
            target_alias: struct {
                directory: DirectoryLease,
                lookup: Directory.AliasMap.RawLookupCursor,
            },
            short_alias: struct {
                directory: DirectoryLease,
                canonical_target: intern.ModuleName,
                lookup: Directory.AliasMap.RawLookupCursor,
            },
            modules_map: struct {
                directory: DirectoryLease,
                canonical_target: intern.ModuleName,
                alias_capacity: usize,
                cloner: Directory.ModuleMap.CloneCursor,
            },
            aliases_map: struct {
                directory: DirectoryLease,
                canonical_target: intern.ModuleName,
                modules: Directory.ModuleMap,
                cloner: Directory.AliasMap.CloneCursor,
            },
            candidate: struct {
                directory: DirectoryLease,
                canonical_target: intern.ModuleName,
                modules: Directory.ModuleMap,
                aliases: Directory.AliasMap,
            },
            insert: struct {
                directory: DirectoryLease,
                candidate: *Directory,
                insertion: Directory.AliasMap.PutCursor,
            },
            commit: struct {
                directory: DirectoryLease,
                candidate: *Directory,
            },
            failed: DirectoryLease,
            complete,
        };

        pub fn init(registry: *Registry, short: intern.BindingName, target: intern.ModuleName) AliasCursor {
            return .{ .registry = registry, .short = short, .target = target };
        }
        pub fn deinit(self: *AliasCursor) void {
            switch (self.state) {
                .snapshot, .complete => {},
                .short_module => |*state| state.directory.deinit(),
                .target_module => |*state| state.directory.deinit(),
                .target_alias => |*state| state.directory.deinit(),
                .short_alias => |*state| state.directory.deinit(),
                .modules_map => |*state| {
                    state.cloner.deinit();
                    state.directory.deinit();
                },
                .aliases_map => |*state| {
                    state.cloner.deinit();
                    state.modules.deinit();
                    state.directory.deinit();
                },
                .candidate => |*state| {
                    state.modules.deinit();
                    state.aliases.deinit();
                    state.directory.deinit();
                },
                .insert => |*state| {
                    self.destroyCandidate(state.candidate);
                    state.directory.deinit();
                },
                .commit => |*state| {
                    self.destroyCandidate(state.candidate);
                    state.directory.deinit();
                },
                .failed => |*directory| directory.deinit(),
            }
            self.* = undefined;
        }
        fn destroyCandidate(self: *AliasCursor, candidate: *Directory) void {
            candidate.modules.deinit();
            candidate.aliases.deinit();
            self.registry.allocator().destroy(candidate);
        }
        pub fn advance(self: *AliasCursor) AliasError!AliasProgress {
            return switch (self.state) {
                .snapshot => result: {
                    const directory = self.registry.acquireDirectory();
                    const old = directory.directory orelse {
                        self.state = .{ .failed = directory };
                        return error.MissingModule;
                    };
                    self.state = .{ .short_module = .{
                        .directory = directory,
                        .lookup = old.modules.rawLookup(intern.moduleNameFromBinding(self.short)),
                    } };
                    break :result .pending;
                },
                .short_module => |*short_module| switch (short_module.lookup.advance()) {
                    .pending => .pending,
                    .complete => |slot| result: {
                        if (slot != null) {
                            const directory = short_module.directory;
                            self.state = .{ .failed = directory };
                            return error.NameConflict;
                        }
                        const directory = short_module.directory;
                        self.state = .{ .target_module = .{
                            .directory = directory,
                            .lookup = directory.directory.?.modules.rawLookup(self.target),
                        } };
                        break :result .pending;
                    },
                },
                .target_module => |*target_module| switch (target_module.lookup.advance()) {
                    .pending => .pending,
                    .complete => |slot| result: {
                        if (slot != null) {
                            const directory = target_module.directory;
                            self.state = .{ .short_alias = .{
                                .directory = directory,
                                .canonical_target = self.target,
                                .lookup = directory.directory.?.aliases.rawLookup(self.short),
                            } };
                        } else {
                            if (intern.moduleBindingName(self.target)) |alias_name| {
                                const directory = target_module.directory;
                                self.state = .{ .target_alias = .{
                                    .directory = directory,
                                    .lookup = directory.directory.?.aliases.rawLookup(alias_name),
                                } };
                            } else {
                                const directory = target_module.directory;
                                self.state = .{ .failed = directory };
                                return error.MissingModule;
                            }
                        }
                        break :result .pending;
                    },
                },
                .target_alias => |*target_alias| switch (target_alias.lookup.advance()) {
                    .pending => .pending,
                    .complete => |canonical_name| result: {
                        const canonical_target = canonical_name orelse {
                            const directory = target_alias.directory;
                            self.state = .{ .failed = directory };
                            return error.MissingModule;
                        };
                        const directory = target_alias.directory;
                        self.state = .{ .short_alias = .{
                            .directory = directory,
                            .canonical_target = canonical_target,
                            .lookup = directory.directory.?.aliases.rawLookup(self.short),
                        } };
                        break :result .pending;
                    },
                },
                .short_alias => |*short_alias| switch (short_alias.lookup.advance()) {
                    .pending => .pending,
                    .complete => |existing| result: {
                        if (existing != null and existing == short_alias.canonical_target) {
                            short_alias.directory.deinit();
                            self.state = .complete;
                            break :result .complete;
                        }
                        const directory = short_alias.directory;
                        const canonical_target = short_alias.canonical_target;
                        const alias_capacity: usize = @intFromBool(existing == null);
                        const cloner = directory.directory.?.modules.cloneCursor(0);
                        self.state = .{ .modules_map = .{
                            .directory = directory,
                            .canonical_target = canonical_target,
                            .alias_capacity = alias_capacity,
                            .cloner = cloner,
                        } };
                        break :result .pending;
                    },
                },
                .modules_map => |*modules_state| switch (try modules_state.cloner.advance()) {
                    .pending => .pending,
                    .complete => |map| result: {
                        const directory = modules_state.directory;
                        const canonical_target = modules_state.canonical_target;
                        const alias_capacity = modules_state.alias_capacity;
                        modules_state.cloner.deinit();
                        const cloner = directory.directory.?.aliases.cloneCursor(alias_capacity);
                        self.state = .{ .aliases_map = .{
                            .directory = directory,
                            .canonical_target = canonical_target,
                            .modules = map,
                            .cloner = cloner,
                        } };
                        break :result .pending;
                    },
                },
                .aliases_map => |*aliases_state| switch (try aliases_state.cloner.advance()) {
                    .pending => .pending,
                    .complete => |map| result: {
                        const directory = aliases_state.directory;
                        const canonical_target = aliases_state.canonical_target;
                        const modules = aliases_state.modules;
                        aliases_state.cloner.deinit();
                        self.state = .{ .candidate = .{
                            .directory = directory,
                            .canonical_target = canonical_target,
                            .modules = modules,
                            .aliases = map,
                        } };
                        break :result .pending;
                    },
                },
                .candidate => |*candidate_state| result: {
                    const candidate = try self.registry.allocator().create(Directory);
                    const directory = candidate_state.directory;
                    const canonical_target = candidate_state.canonical_target;
                    const modules = candidate_state.modules;
                    const aliases = candidate_state.aliases;
                    candidate.* = .{
                        .modules = modules,
                        .aliases = aliases,
                        .previous = @constCast(directory.directory),
                    };
                    const insertion = candidate.aliases.putCursor(
                        self.short,
                        canonical_target,
                    );
                    self.state = .{ .insert = .{
                        .directory = directory,
                        .candidate = candidate,
                        .insertion = insertion,
                    } };
                    break :result .pending;
                },
                .insert => |*insert| switch (insert.insertion.advance()) {
                    .pending => .pending,
                    .complete => result: {
                        const directory = insert.directory;
                        const candidate = insert.candidate;
                        self.state = .{ .commit = .{
                            .directory = directory,
                            .candidate = candidate,
                        } };
                        break :result .pending;
                    },
                },
                .commit => |*commit| result: {
                    self.registry.lockBlocking();
                    if (!self.registry.privateState().directories.isCurrent(commit.directory.directory)) {
                        self.registry.unlock();
                        const candidate = commit.candidate;
                        var directory = commit.directory;
                        self.state = .snapshot;
                        self.destroyCandidate(candidate);
                        directory.deinit();
                        break :result .pending;
                    }
                    self.registry.privateState().directories.publish(commit.candidate);
                    self.registry.unlock();
                    commit.directory.deinit();
                    self.state = .complete;
                    break :result .complete;
                },
                .failed, .complete => unreachable,
            };
        }
    };
    pub fn aliasCursor(
        self: *Registry,
        short: intern.BindingName,
        target: intern.ModuleName,
    ) AliasCursor {
        return .init(self, short, target);
    }

    pub const CanonicalProgress = poll.Progress(?intern.ModuleName);
    pub const CanonicalCursor = struct {
        directory: DirectoryLease,
        name: intern.ModuleName,
        phase: enum { module, alias, complete } = .module,
        module_lookup: ?Directory.ModuleMap.RawLookupCursor = null,
        alias_lookup: ?Directory.AliasMap.RawLookupCursor = null,

        pub fn deinit(self: *CanonicalCursor) void {
            self.directory.deinit();
            self.* = undefined;
        }
        pub fn advance(self: *CanonicalCursor) CanonicalProgress {
            while (true) switch (self.phase) {
                .module => {
                    const lookup = &(self.module_lookup orelse {
                        self.phase = .complete;
                        return .{ .complete = null };
                    });
                    switch (lookup.advance()) {
                        .pending => return .pending,
                        .complete => |slot| if (slot != null) {
                            self.phase = .complete;
                            return .{ .complete = self.name };
                        } else {
                            if (intern.moduleBindingName(self.name)) |alias_name| {
                                self.alias_lookup = self.directory.directory.?.aliases.rawLookup(alias_name);
                                self.phase = .alias;
                            } else {
                                self.phase = .complete;
                                return .{ .complete = null };
                            }
                        },
                    }
                },
                .alias => switch (self.alias_lookup.?.advance()) {
                    .pending => return .pending,
                    .complete => |canonical_name| {
                        self.phase = .complete;
                        return .{ .complete = canonical_name };
                    },
                },
                .complete => unreachable,
            };
        }
    };
    pub fn canonicalCursor(self: *const Registry, name: intern.ModuleName) CanonicalCursor {
        const directory = self.acquireDirectory();
        return .{
            .directory = directory,
            .name = name,
            .module_lookup = if (directory.directory) |current|
                current.modules.rawLookup(name)
            else
                null,
        };
    }

    pub const AcquireProgress = poll.Progress(?GenerationLease);
    pub const AcquireCursor = struct {
        registry: *const Registry,
        directory: DirectoryLease,
        name: intern.ModuleName,
        phase: enum { module, alias, canonical_module, maintenance, complete } = .module,
        module_lookup: ?Directory.ModuleMap.RawLookupCursor = null,
        alias_lookup: ?Directory.AliasMap.RawLookupCursor = null,
        canonical_lookup: ?Directory.ModuleMap.RawLookupCursor = null,
        pending_lease: ?GenerationLease = null,
        maintenance: ?MaintenanceCursor = null,

        pub fn deinit(self: *AcquireCursor) void {
            self.directory.deinit();
            if (self.pending_lease) |*lease| lease.deinit();
            self.* = undefined;
        }
        fn acceptSlot(self: *AcquireCursor, slot: *ModuleSlot) AcquireProgress {
            const protected = self.registry.leaseSlot(slot);
            if (protected.needs_maintenance) {
                self.pending_lease = protected.lease;
                self.maintenance = @constCast(self.registry).maintenanceCursor();
                self.phase = .maintenance;
                return .pending;
            }
            self.phase = .complete;
            return .{ .complete = protected.lease };
        }
        pub fn advance(self: *AcquireCursor) AcquireProgress {
            while (true) switch (self.phase) {
                .module => {
                    const lookup = &(self.module_lookup orelse {
                        self.phase = .complete;
                        return .{ .complete = null };
                    });
                    switch (lookup.advance()) {
                        .pending => return .pending,
                        .complete => |slot| if (slot) |found| {
                            return self.acceptSlot(found);
                        } else {
                            if (intern.moduleBindingName(self.name)) |alias_name| {
                                self.alias_lookup = self.directory.directory.?.aliases.rawLookup(alias_name);
                                self.phase = .alias;
                            } else {
                                self.phase = .complete;
                                return .{ .complete = null };
                            }
                        },
                    }
                },
                .alias => switch (self.alias_lookup.?.advance()) {
                    .pending => return .pending,
                    .complete => |canonical_name| if (canonical_name) |found| {
                        self.canonical_lookup = self.directory.directory.?.modules.rawLookup(found);
                        self.phase = .canonical_module;
                    } else {
                        self.phase = .complete;
                        return .{ .complete = null };
                    },
                },
                .canonical_module => switch (self.canonical_lookup.?.advance()) {
                    .pending => return .pending,
                    .complete => |slot| {
                        return self.acceptSlot(slot orelse unreachable);
                    },
                },
                .maintenance => switch (self.maintenance.?.advance()) {
                    .pending => return .pending,
                    .complete => {
                        const lease = self.pending_lease;
                        self.pending_lease = null;
                        self.maintenance = null;
                        self.phase = .complete;
                        return .{ .complete = lease };
                    },
                },
                .complete => unreachable,
            };
        }
    };
    pub fn acquireCursor(self: *const Registry, name: intern.ModuleName) AcquireCursor {
        const directory = self.acquireDirectory();
        return .{
            .registry = self,
            .directory = directory,
            .name = name,
            .module_lookup = if (directory.directory) |current|
                current.modules.rawLookup(name)
            else
                null,
        };
    }

    const LeaseSlotResult = struct {
        lease: ?GenerationLease,
        needs_maintenance: bool,
    };
    fn leaseSlot(self: *const Registry, slot: *ModuleSlot) LeaseSlotResult {
        _ = self;
        var snapshot_lease = slot.publisher.acquire();
        const generation = snapshot_lease.snapshot;
        if (generation) |present| {
            @constCast(present).retain();
        }
        const final_reader = snapshot_lease.deinit();
        return .{
            .lease = if (generation) |present| GenerationLease.initRetained(@constCast(present)) else null,
            .needs_maintenance = final_reader,
        };
    }

    /// Publishes one borrowed image under `name`. The borrow need only be valid
    /// for this call: the cursor retains its own reference, and a successful
    /// registration holds a third, independent one.
    pub fn register(
        self: *Registry,
        image: ImageRef,
        name: intern.ModuleName,
    ) CommitError!u64 {
        var authority: TurnAuthority = .available;
        var cursor = self.registrationCursor(image, name, &authority);
        defer cursor.deinit();
        return poll.driveFallible(u64, &cursor, .{});
    }

    pub fn alias(
        self: *Registry,
        short: intern.BindingName,
        target: intern.ModuleName,
    ) AliasError!void {
        var cursor = self.aliasCursor(short, target);
        defer cursor.deinit();
        return poll.driveVoidFallible(&cursor, .{});
    }

    pub const BeginLoadingProgress = poll.Progress(LoadingOutcome);
    pub const BeginLoadingCursor = struct {
        registry: *Registry,
        name: intern.ModuleName,
        owner: LoadingOwner,
        observed_head: ?*LoadingNode,
        cursor: ?*LoadingNode,
        reservation: ?*LoadingNode = null,
        phase: enum { scan, reserve, commit, complete } = .scan,

        pub fn deinit(self: *BeginLoadingCursor) void {
            if (self.reservation) |node| self.registry.allocator().destroy(node);
            self.* = undefined;
        }

        fn completeExisting(self: *BeginLoadingCursor, result: LoadingOutcome) BeginLoadingProgress {
            if (self.reservation) |node| self.registry.allocator().destroy(node);
            self.reservation = null;
            self.phase = .complete;
            return .{ .complete = result };
        }

        pub fn advance(self: *BeginLoadingCursor) error{OutOfMemory}!BeginLoadingProgress {
            return switch (self.phase) {
                .scan => result: {
                    const node = self.cursor orelse {
                        self.phase = if (self.reservation == null) .reserve else .commit;
                        break :result .pending;
                    };
                    self.cursor = node.next;
                    if (node.name == self.name) {
                        const held = node.owner.cmpxchgStrong(
                            free_loading_owner,
                            self.owner.token(),
                            .acq_rel,
                            .acquire,
                        ) orelse break :result self.completeExisting(.{ .granted = .init(node) });
                        if (held == self.owner.token())
                            break :result self.completeExisting(.cycle);
                        break :result self.completeExisting(.contended);
                    }
                    break :result .pending;
                },
                .reserve => result: {
                    self.reservation = try self.registry.allocator().create(LoadingNode);
                    self.phase = .commit;
                    break :result .pending;
                },
                .commit => result: {
                    self.registry.lockBlocking();
                    defer self.registry.unlock();
                    const current = self.registry.privateState().loading.load(.acquire);
                    if (current != self.observed_head) {
                        self.observed_head = current;
                        self.cursor = current;
                        self.phase = .scan;
                        break :result .pending;
                    }
                    const node = self.reservation.?;
                    self.reservation = null;
                    node.* = .{
                        .registry = self.registry,
                        .name = self.name,
                        .owner = .init(self.owner.token()),
                        .next = current,
                    };
                    self.registry.privateState().loading.store(node, .release);
                    self.phase = .complete;
                    break :result .{ .complete = .{ .granted = .init(node) } };
                },
                .complete => unreachable,
            };
        }
    };
    pub fn beginLoadingCursor(
        self: *Registry,
        name: intern.ModuleName,
        owner: LoadingOwner,
    ) BeginLoadingCursor {
        const head = self.privateState().loading.load(.acquire);
        return .{
            .registry = self,
            .name = name,
            .owner = owner,
            .observed_head = head,
            .cursor = head,
        };
    }
};
comptime {
    heap.requireOpaqueHostRoot(Registry, RegistryState);
}

/// Blocking drives for tests. Production acquires a generation through the
/// resumable cursor, so a blocking wrapper in the production surface would be
/// an operation nothing calls — and one that lets a test skip the very
/// resumability it should be exercising.
pub const testing = if (builtin.is_test) struct {
    pub fn acquire(registry: *const Registry, name: intern.ModuleName) ?GenerationLease {
        var cursor = registry.acquireCursor(name);
        defer cursor.deinit();
        return poll.drive(?GenerationLease, &cursor, .{});
    }
} else struct {};
