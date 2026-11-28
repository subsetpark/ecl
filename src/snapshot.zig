//! One publication/reader handoff for immutable runtime snapshots.
//!
//! A lease is the only public way to obtain a traversable pointer. Payload
//! retention and reclamation remain the owner's responsibility because their
//! work must be routed through the owner's bounded cursor/release domain.
//!
//! Reclamation is by epoch, so its lag is bounded by readers' lengths and
//! never needs an instant with no reader at all. There are two epochs, one
//! current, and one reader count for each. A reader counts itself under the
//! epoch it read as current. The owner keeps two lists of superseded
//! snapshots: `pending`, superseded since the last flip, which the owner
//! holds, and `draining`, superseded before it, which the publisher holds.
//! `rotate`, called under the owner's writer lock, flips the epoch only when
//! the epoch it flips to has no reader; it then hands back `draining` for
//! reclamation and takes `pending` as the next `draining`.
//!
//! Invariant: a snapshot superseded while epoch E was current is reclaimed
//! only by the second flip after it was superseded: away from E, then back.
//! Proof that no reader still holds it. A reader loads a pointer only after
//! it has counted itself, so a snapshot it holds was superseded after its
//! count, under whichever epoch it counted. Publication and rotation are
//! serialized by the owner's writer lock, so both of those flips test their
//! counts after the snapshot was superseded, hence after the reader's
//! count. One of any two consecutive flips is a flip to the reader's epoch,
//! and that one finds its count nonzero until the reader leaves. A reader
//! may therefore count itself under an epoch that has just stopped being
//! current; it only delays the next flip back, like any reader of that
//! epoch.
//!
//! Every atomic here is sequentially consistent, and the proof needs it: a
//! reader's count increment followed by its pointer load, and a writer's
//! pointer store followed by a rotation's count load, are two
//! store-then-load pairs on different atomics. One total order is what
//! makes one party see the other: either the reader loads the successor,
//! or the rotation observes the reader's count.
const std = @import("std");

pub fn Publisher(comptime T: type) type {
    return struct {
        const Self = @This();

        current: std.atomic.Value(?*T),
        /// The epoch entering readers count themselves under. Written only
        /// by `rotate`, under the owner's writer lock.
        epoch: std.atomic.Value(u8) = .init(0),
        readers: [2]std.atomic.Value(u32) = .{ .init(0), .init(0) },
        /// Snapshots superseded before the last flip, while the epoch that
        /// is now not current was. Read and written only by `rotate`.
        draining_list: ?*T = null,

        /// One announced reader that holds no snapshot: nothing superseded
        /// since it entered is reclaimed before it leaves.
        pub const Reader = struct {
            epoch: u8,
        };

        pub const Lease = struct {
            publisher: *const Self,
            snapshot: ?*const T,
            reader: Reader,
            active: bool = true,

            /// Returns true when this reader emptied its epoch. The caller
            /// then rotates under its writer lock, and reclaims what the
            /// rotation hands back after releasing that lock.
            pub fn deinit(self: *Lease) bool {
                std.debug.assert(self.active);
                self.active = false;
                const emptied = self.publisher.leave(self.reader);
                self.* = undefined;
                return emptied;
            }
        };

        pub fn init(initial: ?*T) Self {
            return .{ .current = .init(initial) };
        }

        /// Announces a reader under the epoch it reads as current. No
        /// second look at the epoch is needed: see the proof above.
        pub fn enter(self: *const Self) Reader {
            const mutable = @constCast(self);
            const epoch = mutable.epoch.load(.seq_cst);
            const old = mutable.readers[epoch].fetchAdd(1, .seq_cst);
            std.debug.assert(old != std.math.maxInt(u32));
            return .{ .epoch = epoch };
        }

        /// Ends a reader. Returns true when it emptied its epoch, with the
        /// caller's duties as for a lease.
        pub fn leave(self: *const Self, reader: Reader) bool {
            const old = @constCast(self).readers[reader.epoch].fetchSub(1, .seq_cst);
            std.debug.assert(old != 0);
            return old == 1;
        }

        pub fn acquire(self: *const Self) Lease {
            const reader = self.enter();
            return .{
                .publisher = self,
                .reader = reader,
                .snapshot = self.current.load(.seq_cst),
            };
        }

        /// Writer-serialized publication. The owner validates the expected
        /// pointer before calling this method.
        pub fn publish(self: *Self, next: ?*T) void {
            self.current.store(next, .seq_cst);
        }

        pub fn isCurrent(self: *const Self, expected: ?*const T) bool {
            return self.current.load(.seq_cst) == @constCast(expected);
        }

        /// Owner-only access for writer-locked reclamation and final teardown.
        pub fn currentOwned(self: *const Self) ?*T {
            return self.current.load(.seq_cst);
        }

        /// Whether a rotation would flip now. Writer-locked.
        pub fn mayRotate(self: *const Self) bool {
            const other = 1 - self.epoch.load(.seq_cst);
            return self.readers[other].load(.seq_cst) == 0;
        }

        /// Writer-locked, and only when `mayRotate` held under the same
        /// lock: flips the epoch, takes `pending` (what the owner has
        /// superseded since the last flip) as the draining list, and returns
        /// the previous draining list, which no reader holds any more. The
        /// count is not read a second time: a reader that read the epoch
        /// before the last flip may count itself under the epoch flipped to
        /// at any instant, which the proof above allows.
        pub fn rotate(self: *Self, pending: ?*T) ?*T {
            const epoch = self.epoch.load(.seq_cst);
            const reclaimable = self.draining_list;
            self.draining_list = pending;
            self.epoch.store(1 - epoch, .seq_cst);
            return reclaimable;
        }

        /// Whether a draining list waits. Writer-locked.
        pub fn draining(self: *const Self) bool {
            return self.draining_list != null;
        }

        /// The draining list, for final teardown once no reader remains.
        pub fn takeDraining(self: *Self) ?*T {
            defer self.draining_list = null;
            return self.draining_list;
        }

        pub fn quiescent(self: *const Self) bool {
            return self.readers[0].load(.seq_cst) == 0 and self.readers[1].load(.seq_cst) == 0;
        }
    };
}
